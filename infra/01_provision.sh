#!/usr/bin/env bash
#
# Provision the deployment infrastructure: registry, secret, roles, log group.
#
# Idempotent — safe to re-run. Every step checks for an existing resource before
# creating one, so a partial failure can be recovered by running it again rather
# than by unpicking what already succeeded.
#
#     ./infra/01_provision.sh
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

REPO_NAME="sakuracon-pipeline"
CLUSTER_NAME="sakuracon-cluster"
SECRET_NAME="sakuracon/pipeline"
LOG_GROUP="/ecs/sakuracon-pipeline"
EXEC_ROLE="sakuracon-task-execution-role"
TASK_ROLE="sakuracon-task-role"
# The bucket name is account-specific, so it comes from .env (S3_RAW_BUCKET)
# like every other setting instead of being written into this script.
S3_BUCKET="${S3_RAW_BUCKET:-}"
if [[ -z "$S3_BUCKET" && -f .env ]]; then
    S3_BUCKET="$(sed -n 's/^S3_RAW_BUCKET=//p' .env | tr -d "\"' ")"
fi
if [[ -z "$S3_BUCKET" ]]; then
    echo "ERROR: set S3_RAW_BUCKET in .env and run from the aws_pipeline directory." >&2
    exit 1
fi

echo "Account ${ACCOUNT_ID} / region ${REGION}"

# ---------------------------------------------------------------------------
# 1. ECR repository
# ---------------------------------------------------------------------------
if aws ecr describe-repositories --repository-names "$REPO_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "ECR repository ${REPO_NAME} already exists"
else
    aws ecr create-repository \
        --repository-name "$REPO_NAME" \
        --region "$REGION" \
        --image-scanning-configuration scanOnPush=true \
        --image-tag-mutability IMMUTABLE >/dev/null
    echo "Created ECR repository ${REPO_NAME}"
fi

# Untagged images accumulate on every push and are billed for. Expire them.
aws ecr put-lifecycle-policy \
    --repository-name "$REPO_NAME" --region "$REGION" \
    --lifecycle-policy-text '{
      "rules": [
        {
          "rulePriority": 1,
          "description": "Expire untagged images after 7 days",
          "selection": {
            "tagStatus": "untagged",
            "countType": "sinceImagePushed",
            "countUnit": "days",
            "countNumber": 7
          },
          "action": {"type": "expire"}
        },
        {
          "rulePriority": 2,
          "description": "Keep only the 10 most recent tagged images",
          "selection": {
            "tagStatus": "any",
            "countType": "imageCountMoreThan",
            "countNumber": 10
          },
          "action": {"type": "expire"}
        }
      ]
    }' >/dev/null
echo "Lifecycle policy applied"

# ---------------------------------------------------------------------------
# 2. CloudWatch log group
# ---------------------------------------------------------------------------
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$REGION" \
     --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
    echo "Log group ${LOG_GROUP} already exists"
else
    aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION"
    echo "Created log group ${LOG_GROUP}"
fi

# Logs are billed for storage indefinitely by default. 30 days is ample for
# debugging a daily job and keeps the cost at effectively nothing.
aws logs put-retention-policy \
    --log-group-name "$LOG_GROUP" --retention-in-days 30 --region "$REGION"

# ---------------------------------------------------------------------------
# 3. Secrets Manager — every runtime setting as one JSON document
# ---------------------------------------------------------------------------
# Built from the local .env so there is a single source of truth, and so the
# secret's contents never appear in this script or in shell history.
if [[ ! -f .env ]]; then
    echo "ERROR: .env not found. Run from the aws_pipeline directory." >&2
    exit 1
fi

SECRET_JSON="$(python3 - <<'PY'
import json, pathlib
pairs = {}
for line in pathlib.Path(".env").read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    pairs[key.strip()] = value.strip()
print(json.dumps(pairs))
PY
)"

if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value \
        --secret-id "$SECRET_NAME" --secret-string "$SECRET_JSON" --region "$REGION" >/dev/null
    echo "Updated secret ${SECRET_NAME}"
else
    aws secretsmanager create-secret \
        --name "$SECRET_NAME" \
        --description "Runtime configuration for the Sakura-Con sales pipeline" \
        --secret-string "$SECRET_JSON" --region "$REGION" >/dev/null
    echo "Created secret ${SECRET_NAME}"
fi

SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
    --region "$REGION" --query ARN --output text)"

# ---------------------------------------------------------------------------
# 4. IAM roles
# ---------------------------------------------------------------------------
# Two roles, deliberately separate:
#
#   execution role — used by the ECS *agent* to start the task: pull the image
#                    from ECR and create the log stream. It never runs your code.
#   task role      — assumed by the *container itself*. This is what your Python
#                    uses to read the secret and write to S3.
#
# Collapsing them into one is common and wrong: it hands your application code
# permission to pull arbitrary images and manage log groups, neither of which it
# has any reason to do.

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ecs-tasks.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

create_role () {
    local name="$1"
    if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
        echo "Role ${name} already exists"
    else
        aws iam create-role --role-name "$name" \
            --assume-role-policy-document "$TRUST_POLICY" >/dev/null
        echo "Created role ${name}"
    fi
}

create_role "$EXEC_ROLE"
create_role "$TASK_ROLE"

aws iam attach-role-policy --role-name "$EXEC_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# The task role gets exactly two permissions: read its own secret, and read and
# write objects under its own bucket. Nothing else.
aws iam put-role-policy --role-name "$TASK_ROLE" \
    --policy-name sakuracon-task-permissions \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Sid\": \"ReadOwnSecret\",
          \"Effect\": \"Allow\",
          \"Action\": \"secretsmanager:GetSecretValue\",
          \"Resource\": \"${SECRET_ARN}\"
        },
        {
          \"Sid\": \"ReadWriteOwnBucketObjects\",
          \"Effect\": \"Allow\",
          \"Action\": [\"s3:GetObject\", \"s3:PutObject\", \"s3:DeleteObject\"],
          \"Resource\": \"arn:aws:s3:::${S3_BUCKET}/*\"
        },
        {
          \"Sid\": \"ListOwnBucket\",
          \"Effect\": \"Allow\",
          \"Action\": \"s3:ListBucket\",
          \"Resource\": \"arn:aws:s3:::${S3_BUCKET}\"
        }
      ]
    }"
echo "Task role permissions attached"

# ---------------------------------------------------------------------------
# 5. ECS cluster
# ---------------------------------------------------------------------------
# A Fargate cluster is just a logical grouping — no servers, no standing cost.
if aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$REGION" \
     --query 'clusters[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
    echo "Cluster ${CLUSTER_NAME} already exists"
else
    aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$REGION" >/dev/null
    echo "Created cluster ${CLUSTER_NAME}"
fi

# ---------------------------------------------------------------------------
# 6. Let the Fargate task reach Redshift
# ---------------------------------------------------------------------------
# The task gets a new private IP on every run, so an address-based rule is
# useless here — that is why the two /32 rules for a laptop do not help a
# container. The rule below references the task's *security group* instead:
# anything attached to that group may reach Redshift on 5439, whatever address
# it happens to have today. This is the normal way to express "these two
# components may talk to each other".
#
# Skipped if the workgroup does not exist yet — see AWS_SETUP.md.

WORKGROUP="${REDSHIFT_WORKGROUP:-sakuracon-wg}"

# Distinguish "no warehouse yet" from "you lack permission to look". Swallowing
# both would let a permissions error print the same reassuring skip message and
# leave the task unable to reach Redshift, which fails much later and elsewhere.
REDSHIFT_SG=""
if WG_JSON="$(aws redshift-serverless get-workgroup \
        --workgroup-name "$WORKGROUP" --region "$REGION" 2>&1)"; then
    REDSHIFT_SG="$(python3 -c \
        "import json,sys; print(json.load(sys.stdin)['workgroup']['securityGroupIds'][0])" \
        <<<"$WG_JSON")"
elif grep -q "ResourceNotFoundException" <<<"$WG_JSON"; then
    echo "Workgroup ${WORKGROUP} not found — skipping Redshift ingress rule"
else
    echo "ERROR looking up workgroup ${WORKGROUP}:" >&2
    echo "$WG_JSON" >&2
    exit 1
fi

if [[ -z "$REDSHIFT_SG" || "$REDSHIFT_SG" == "None" ]]; then
    :
else
    VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
        --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
    TASK_SG="$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" Name=group-name,Values=default \
        --query 'SecurityGroups[0].GroupId' --output text)"

    # Capture stderr so an "already exists" can be told apart from a genuine
    # failure. Swallowing both would let a permissions error look like success.
    ERR="$(aws ec2 authorize-security-group-ingress \
        --group-id "$REDSHIFT_SG" \
        --protocol tcp --port 5439 \
        --source-group "$TASK_SG" \
        --region "$REGION" 2>&1 >/dev/null)" && ERR=""

    if [[ -z "$ERR" ]]; then
        echo "Allowed ${TASK_SG} -> ${REDSHIFT_SG} on 5439"
    elif grep -q "InvalidPermission.Duplicate" <<<"$ERR"; then
        echo "Redshift ingress rule already present (${TASK_SG} -> ${REDSHIFT_SG}:5439)"
    else
        echo "ERROR opening Redshift to the task security group:" >&2
        echo "$ERR" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
echo
echo "Provisioned. Values needed for the next steps:"
echo "  ECR repository : ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"
echo "  Secret ARN     : ${SECRET_ARN}"
echo "  Execution role : arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE}"
echo "  Task role      : arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE}"
echo "  Log group      : ${LOG_GROUP}"
echo "  Cluster        : ${CLUSTER_NAME}"
