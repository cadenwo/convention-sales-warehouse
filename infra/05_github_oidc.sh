#!/usr/bin/env bash
#
# Let GitHub Actions deploy to AWS without storing any AWS credentials.
#
#     GITHUB_REPO=<your-github-username>/convention-sales-warehouse ./infra/05_github_oidc.sh
#
# The alternative — putting an access key and secret into GitHub repository
# secrets — is what most tutorials do, and it means a long-lived credential to
# your AWS account sits in a third-party system indefinitely. If the repo is
# ever compromised, or a malicious action in a workflow exfiltrates it, that key
# keeps working until someone notices and rotates it.
#
# OIDC replaces that with a trust relationship. GitHub mints a short-lived token
# describing which repository and branch is running; AWS verifies it against
# GitHub's public keys and issues temporary credentials that expire in an hour.
# Nothing secret is ever stored, and the trust condition below means only *this*
# repository can assume the role.
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_NAME="sakuracon-github-deploy"
REPO_NAME="sakuracon-pipeline"

if [[ -z "${GITHUB_REPO:-}" ]]; then
    echo "ERROR: set GITHUB_REPO to owner/repo, e.g. GITHUB_REPO=you/convention-sales-warehouse" >&2
    exit 1
fi

# GitHub's OIDC token names this repository by immutable IDs as well as names:
# repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main. Pinning the IDs means a
# repository deleted and recreated under the same name cannot inherit this
# trust. The IDs come from GitHub's public API, so only owner/repo is needed.
SUBJECT_REPO="$(curl -fsS "https://api.github.com/repos/${GITHUB_REPO}" | python3 -c '
import json, sys
r = json.load(sys.stdin)
print("{}@{}/{}@{}".format(r["owner"]["login"], r["owner"]["id"], r["name"], r["id"]))
')" || { echo "ERROR: could not look up ${GITHUB_REPO} on api.github.com. Is it public?" >&2; exit 1; }
SUBJECT="repo:${SUBJECT_REPO}:ref:refs/heads/main"

PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

# ---------------------------------------------------------------------------
# 1. Register GitHub as an identity provider (once per account)
# ---------------------------------------------------------------------------
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
    echo "OIDC provider already registered"
else
    aws iam create-open-id-connect-provider \
        --url https://token.actions.githubusercontent.com \
        --client-id-list sts.amazonaws.com \
        --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
    echo "Registered GitHub OIDC provider"
fi

# ---------------------------------------------------------------------------
# 2. A role only this repository's main branch can assume
# ---------------------------------------------------------------------------
# The `sub` condition is the security boundary. Without it — or with a wildcard
# — *any* GitHub repository in the world could assume this role.
TRUST="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${PROVIDER_ARN}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "${SUBJECT}"
      }
    }
  }]
}
JSON
)"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
        --policy-document "$TRUST" >/dev/null
    echo "Updated trust policy on ${ROLE_NAME} for ${SUBJECT}"
else
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST" >/dev/null
    echo "Created ${ROLE_NAME} for ${SUBJECT}"
fi

# ---------------------------------------------------------------------------
# 3. Only what a deploy needs: push an image, register a task definition
# ---------------------------------------------------------------------------
# Note it cannot *run* tasks, delete anything, or touch the secret. A compromised
# workflow could publish a bad image; it could not read your credentials or
# start a container with them.
aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name sakuracon-deploy-permissions \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Sid\": \"GetEcrLoginToken\",
          \"Effect\": \"Allow\",
          \"Action\": \"ecr:GetAuthorizationToken\",
          \"Resource\": \"*\"
        },
        {
          \"Sid\": \"PushToOwnRepositoryOnly\",
          \"Effect\": \"Allow\",
          \"Action\": [
            \"ecr:BatchCheckLayerAvailability\",
            \"ecr:CompleteLayerUpload\",
            \"ecr:InitiateLayerUpload\",
            \"ecr:PutImage\",
            \"ecr:UploadLayerPart\",
            \"ecr:BatchGetImage\"
          ],
          \"Resource\": \"arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${REPO_NAME}\"
        },
        {
          \"Sid\": \"RegisterNewTaskDefinitionRevisions\",
          \"Effect\": \"Allow\",
          \"Action\": [\"ecs:RegisterTaskDefinition\", \"ecs:DescribeTaskDefinition\"],
          \"Resource\": \"*\"
        },
        {
          \"Sid\": \"PassTaskRolesToEcsOnly\",
          \"Effect\": \"Allow\",
          \"Action\": \"iam:PassRole\",
          \"Resource\": [
            \"arn:aws:iam::${ACCOUNT_ID}:role/sakuracon-task-execution-role\",
            \"arn:aws:iam::${ACCOUNT_ID}:role/sakuracon-task-role\"
          ],
          \"Condition\": {\"StringEquals\": {\"iam:PassedToService\": \"ecs-tasks.amazonaws.com\"}}
        }
      ]
    }"

echo
echo "Add this as a repository variable named AWS_DEPLOY_ROLE in GitHub:"
echo "  arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo
echo "  Settings -> Secrets and variables -> Actions -> Variables -> New variable"
echo "  (a variable, not a secret — a role ARN is an address, not a credential)"
