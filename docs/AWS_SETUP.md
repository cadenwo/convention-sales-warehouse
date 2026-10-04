# AWS Setup

Provisions the two AWS resources this pipeline needs: an S3 bucket for the raw
layer and a Redshift Serverless warehouse for the star schema.

Region for everything: **us-east-1 (N. Virginia)**.

> **Cost.** Redshift Serverless has a **free trial: $300 of credit, usable
> within 90 days**, for accounts that have never used Redshift Serverless. That
> is far more than this project can consume.
>
> After the trial, billing is per RPU-second with a 60-second minimum charge per
> activation, around $0.375 per RPU-hour. At the 4-RPU minimum that is ~$1.50
> per hour *while a query is actually running* — and this pipeline runs for
> about a minute a day, so roughly $0.03/day. The danger is not normal use; it
> is a misconfigured workgroup that never pauses. Steps 2 and 6 are what prevent
> that, and neither is optional.

---

## 1. Create the account

Sign up at <https://aws.amazon.com/free>. A credit card is required; AWS places
a temporary ~$1 authorisation and refunds it.

Immediately enable MFA on the root user:

`Account menu → Security credentials → Multi-factor authentication → Assign MFA device`

Use an authenticator app. Root can delete everything in the account, and a
leaked root credential without MFA is the most common way student AWS accounts
get hijacked for crypto mining — which ends in a five-figure bill. After this
step, stop using root.

---

## 2. Billing guardrails — before creating any resource

**Zero-spend budget:**

`Billing and Cost Management → Budgets → Create budget → Use a template → Zero spend budget`

Alerts you the moment the bill exceeds $0.01. First two budgets are free.

**A second budget with a real ceiling**, so one alert failing isn't fatal:

`Create budget → Customize → Cost budget → Monthly → $10 → alert at 50%, 80%, 100%`

**Free Tier alerts:**

`Billing preferences → Alert preferences → enable "Receive AWS Free Tier alerts"
and "Receive CloudWatch billing alerts" → Save`

---

## 3. Create an IAM user

`IAM → Users → Create user`

- Name: `sakura-admin`
- Enable console access if you want a separate login
- Attach `AmazonS3FullAccess` and `AmazonRedshiftFullAccess`

> Broader than production would grant. Acceptable for a personal project —
> but know that it *is* a trade-off. Phase 3 creates a properly scoped
> execution role for the Fargate task, which is where least privilege matters.

Create an access key: `Security credentials → Create access key → CLI`. The
secret is shown once.

---

## 4. Configure the CLI

```bash
brew install awscli
aws configure          # key, secret, us-east-1, json
aws sts get-caller-identity   # should print your account and sakura-admin ARN
```

---

## 5. Create the S3 bucket

Bucket names are globally unique, so add something personal.

```bash
BUCKET=sakuracon-sales-cwong

aws s3 mb "s3://$BUCKET" --region us-east-1

# The raw layer holds unscrubbed exports — card suffixes, customer names.
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# An accidental overwrite of the raw layer is otherwise unrecoverable.
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
```

---

## 6. Create the Redshift Serverless warehouse

Two objects: a **namespace** (the database and its storage) and a **workgroup**
(the compute that queries it).

`Redshift → Redshift Serverless → Create workgroup`

| Setting | Value | Why |
|---|---|---|
| Workgroup name | `sakuracon-wg` | |
| Base capacity | **4 RPUs** (the minimum) | Capacity is the main cost lever, and 4 is vastly more than 112 rows needs. |
| Max capacity (MaxRPU) | **8 RPUs** | Ceiling on autoscaling, so a runaway query cannot scale up and bill more. |
| VPC / subnets | defaults | |
| Publicly accessible | **Yes, for now** | So your Mac and Tableau Desktop can connect during setup. Firewalled in step 7; turned off in step 10. |
| Namespace name | `sakuracon-ns` | |
| Admin username | your choice | Goes in `.env` as `PGUSER`. |
| Admin password | (save it) | |
| Database name | `dev` (the default) | |

Provisioning takes a few minutes.

Then set a usage limit — this is the hard stop a forgotten session cannot cross:

`Redshift Serverless → Workgroups → sakuracon-wg → Limits tab → Manage usage limits`

Add a limit of **20 RPU-hours**, frequency **Daily**, action **Turn off user
queries**. Daily rather than monthly is deliberate: a monthly cap can burn three
weeks of budget in one bad night before it trips.

The three available actions are *Log to system table* and *Alert* (both
informational only — they notify and let the queries keep running) and *Turn off
user queries*, which is the only one that actually stops spend. Choose the third.

Serverless pauses on its own when idle, so no separate idle-timeout setting is
needed; the usage limit exists to catch the case where something is *not* idle
when it should be.

---

## 7. Restrict network access to your IP

`Redshift Serverless → sakuracon-wg → Network and security → the attached security group → Inbound rules → Edit`

Add: Type `Redshift`, Port `5439`, Source **My IP**.

Never `0.0.0.0/0`. An internet-exposed database port is scanned within minutes.
Note "My IP" pins your current address, so update the rule if your address
changes.

---

## 8. Connect

Endpoint: `Redshift Serverless → Workgroups → sakuracon-wg → Endpoint`.

Redshift speaks the PostgreSQL wire protocol, so `psycopg2`, `psql`, DBeaver
and Tableau all connect to it as if it were Postgres — which is why the
pipeline code needs no new driver.

Add to `aws_pipeline/.env` (git-ignored):

```
PGHOST=sakuracon-wg.<account-id>.us-east-1.redshift-serverless.amazonaws.com
PGPORT=5439
PGDATABASE=dev
PGUSER=your-admin-username
PGPASSWORD=your-password
PGSSLMODE=require
```

Test:

```bash
python3 -c "
import os,sys; sys.path.insert(0,'src')
from config import get_settings
import psycopg2
s=get_settings()
c=psycopg2.connect(host=s['PGHOST'],port=s['PGPORT'],dbname=s['PGDATABASE'],
                   user=s['PGUSER'],password=s['PGPASSWORD'],sslmode='require')
print(c.cursor().execute('select version()') or c.cursor().fetchone())
"
```

---

## 9. Run the pipeline

```bash
python3 scripts/run_pipeline.py --backfill --init
```

The audit line at the end compares staging rows against fact rows and staging
revenue against fact revenue. **They must match.** A mismatch means a join
dropped rows.

---

## 10. Cost control

The $300 trial credit, the 4-RPU floor and the daily usage limit from step 6 keep
Redshift compute close to free, and Serverless pauses itself when idle. What they
don't cover is the public IPv4 address a publicly accessible workgroup holds:
about $3.60 a month, which was most of this project's measured bill. Once you no
longer need a connection from your Mac, turn public access off. Fargate reaches
the warehouse privately and doesn't need it:

```bash
aws redshift-serverless update-workgroup --workgroup-name sakuracon-wg --no-publicly-accessible
```

To check Redshift's spend (drop the `--filter` line to see every service):

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -v1d +%Y-%m-%d),End=$(date -v+1d +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Redshift"]}}'
```

**Full teardown** once the dashboard is captured and the project is documented
— run this rather than leaving the workgroup up indefinitely:

```bash
aws redshift-serverless delete-workgroup --workgroup-name sakuracon-wg
aws redshift-serverless delete-namespace --namespace-name sakuracon-ns \
    --final-snapshot-name sakuracon-final --final-snapshot-retention-period 30
```

The final snapshot preserves the data cheaply, so the warehouse can be restored
for a demo without paying for idle compute in the meantime. S3 costs pennies at
this volume and can stay.
