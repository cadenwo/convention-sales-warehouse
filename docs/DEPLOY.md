# Deployment

Takes the pipeline from "runs on my laptop when I type a command" to "runs
itself every morning in the cloud."

Five scripts, run once each in order. All are idempotent — re-running one is
safe, so a partial failure is recovered by running it again rather than by
unpicking what already worked.

| File | What it does |
|---|---|
| `infra/deployer-policy.json` | The permissions these scripts need. Attach before anything else. |
| `infra/01_provision.sh` | ECR, Secrets Manager, IAM roles, log group, cluster |
| `infra/02_deploy_task.sh` | Build image, push, register task definition |
| `infra/03_run_once.sh` | Run it once and tail the logs |
| `infra/04_schedule.sh` | EventBridge daily trigger |
| `infra/05_github_oidc.sh` | Let CI deploy without storing AWS keys |

Run everything from the `aws_pipeline` directory, one script at a time, checking
the output of each before starting the next.

---

## 0. Permissions

A fresh IAM user cannot create any of this. `deployer-policy.json` is the exact
permission set the five scripts need — attach it once, as an account
administrator, before running anything:

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
sed "s/ACCOUNT_ID/${ACCOUNT_ID}/g" infra/deployer-policy.json > /tmp/deployer-policy.json

aws iam create-policy \
    --policy-name sakuracon-deployer \
    --policy-document file:///tmp/deployer-policy.json

aws iam attach-user-policy \
    --user-name YOUR_IAM_USER \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/sakuracon-deployer"
```

The policy file uses `ACCOUNT_ID` as a placeholder, which the first two lines fill
in.

It is scoped rather than `AdministratorAccess` on purpose. IAM role management
is limited to `sakuracon-*`, `iam:AttachRolePolicy` is conditioned to the single
managed policy the provisioning script attaches, and `iam:PassRole` is
conditioned on `iam:PassedToService`. Together those close the usual escalation
path, where a deploy identity attaches `AdministratorAccess` to a role it
controls and then assumes it.

---

## What gets created

| Resource | Purpose |
|---|---|
| ECR repository | Stores the container image. Fargate cannot read from your laptop. |
| Secrets Manager secret | Every runtime setting, uploaded from your local `.env`. |
| Execution role | Used by the ECS agent to pull the image and write logs. Never runs your code. |
| Task role | Assumed by the container. Reads the secret, reads and writes S3. |
| CloudWatch log group | 30-day retention. Where `log.info` ends up. |
| ECS cluster | A logical grouping. No servers, no standing cost. |
| Task definition | CPU, memory, image, roles, environment. |
| EventBridge schedule | Fires the task at 06:00 Pacific daily. |
| GitHub OIDC role | Lets CI push images without a stored AWS credential. |

---

## 1. Provision

```bash
./infra/01_provision.sh
```

Reads your `.env` and uploads it to Secrets Manager as a single JSON document.
`config.py` already knows how to read it — that is what `PIPELINE_SECRET_NAME`
does — so the container gets exactly the configuration your laptop has, without
any of it appearing in the image, the task definition, or this repository.

**Re-run this after changing `.env`.** The secret does not update itself.

## 2. Build and deploy

```bash
./infra/02_deploy_task.sh
```

Builds with `--platform linux/amd64`. On an Apple Silicon Mac the default build
is arm64, which Fargate cannot run — the task dies at startup with an exec
format error that says nothing about architecture. This is the single most
common first-deployment failure.

Images are tagged with the git commit, never `:latest`. A mutable tag makes
"which code produced this run?" unanswerable after the fact.

## 3. Verify

```bash
./infra/03_run_once.sh --backfill --init
```

Runs the task, waits for it to stop, prints its CloudWatch logs, and exits
non-zero if the container did. You should see the same output as a local run:
Square extraction, S3 archive, Redshift `COPY`, then dbt's models and tests.

If it fails, the logs are the first place to look:

```bash
aws logs tail /ecs/sakuracon-pipeline --follow --region us-east-1
```

## 4. Schedule

```bash
./infra/04_schedule.sh
```

06:00 Pacific daily, with the 24-hour incremental window. Late enough that the
previous day is closed out; early enough that a failure is visible before the
working day starts.

Failed runs retry twice with backoff, then stop. Retrying indefinitely would
hammer Square through an outage; not retrying loses a day to a transient blip.

**Most days this will find zero new orders and do nothing.** That is correct
behaviour for a business that sells at occasional conventions, not a broken
pipeline. When the next event happens the data flows in without intervention.

## 5. CI

```bash
GITHUB_REPO=<your-org>/<your-repo> ./infra/05_github_oidc.sh
```

Then add the printed role ARN as a repository **variable** (not a secret) named
`AWS_DEPLOY_ROLE`, under Settings → Secrets and variables → Actions → Variables.
A role ARN is an address, not a credential.

After that, every push to `main` runs the test suite, and — only if it passes —
builds the image, pushes it, and registers a new task definition revision.

---

## Why OIDC instead of stored AWS keys

The common approach is to create an IAM user, generate an access key, and paste
it into GitHub repository secrets. That leaves a long-lived credential to your
AWS account sitting in a third-party system indefinitely, working until someone
notices and rotates it.

OIDC replaces the stored key with a trust relationship. GitHub mints a
short-lived token stating which repository and branch is running; AWS verifies
it against GitHub's public keys and issues credentials that expire within the
hour. Nothing secret is stored, and the trust policy names exactly one
repository and one branch.

The deploy role also cannot *run* tasks, read the secret, or delete anything. A
compromised workflow could publish a bad image. It could not read your
credentials or start a container holding them.

---

## Cost

Fargate bills per second of task runtime. At 512 CPU units and 1 GB for roughly
a minute a day, that is a few cents a month. ECR storage is trivial at this
image size, and the lifecycle policy expires untagged layers after 7 days and
keeps only the ten most recent images. CloudWatch retention is capped at 30
days.

Measured in Cost Explorer with credits excluded, September came to $4.05. $3.60 of
it was the public IPv4 address a publicly accessible warehouse holds, which the
pipeline never needed; public access is now off. Secrets Manager is $0.40 a month,
and Redshift Serverless compute bills only while a run is active — see
`AWS_SETUP.md` for its usage limit and the teardown steps.

---

## Rolling back

Task definitions are versioned, so rolling back is repointing the schedule at an
older revision:

```bash
aws ecs list-task-definitions --family-prefix sakuracon-pipeline --region us-east-1
```

Each revision points at an immutable image tag, so an older revision is
genuinely the older code — not old configuration pointing at a moved tag. That is the
practical reason for never deploying `:latest`.
