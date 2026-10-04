#!/usr/bin/env bash
#
# Run the pipeline task once, on demand, and tail its logs.
#
#     ./infra/03_run_once.sh                    # incremental, last 24h
#     ./infra/03_run_once.sh --backfill --init  # full rebuild
#
# The first real deployment test. Overriding the container command lets the
# same task definition serve both the scheduled incremental run and an ad-hoc
# backfill without registering a second revision.
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
CLUSTER="sakuracon-cluster"
FAMILY="sakuracon-pipeline"
LOG_GROUP="/ecs/sakuracon-pipeline"

ARGS=("$@")
if [[ ${#ARGS[@]} -eq 0 ]]; then
    ARGS=("--lookback-hours" "24")
fi

# Fargate needs a subnet and a security group. The default VPC's subnets have a
# route to an internet gateway, which the task requires to reach Square, S3 and
# Redshift — hence assignPublicIp=ENABLED. A production setup would use private
# subnets with a NAT gateway, which costs ~$32/month and buys nothing here.
VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
    --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
SUBNET_ID="$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[0].SubnetId' --output text)"
SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" Name=group-name,Values=default \
    --query 'SecurityGroups[0].GroupId' --output text)"

OVERRIDES="$(python3 -c "
import json, sys
print(json.dumps({'containerOverrides': [{'name': 'pipeline', 'command': sys.argv[1:]}]}))
" "${ARGS[@]}")"

echo "Starting task with: ${ARGS[*]}"

TASK_ARN="$(aws ecs run-task \
    --cluster "$CLUSTER" \
    --task-definition "$FAMILY" \
    --launch-type FARGATE \
    --region "$REGION" \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}" \
    --overrides "$OVERRIDES" \
    --query 'tasks[0].taskArn' --output text)"

TASK_ID="${TASK_ARN##*/}"
echo "Task ${TASK_ID} starting; waiting for it to finish..."

aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK_ARN" --region "$REGION"

EXIT_CODE="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
    --region "$REGION" --query 'tasks[0].containers[0].exitCode' --output text)"
REASON="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" \
    --region "$REGION" --query 'tasks[0].stoppedReason' --output text)"

echo
echo "===== logs ====="
aws logs tail "$LOG_GROUP" --region "$REGION" \
    --log-stream-names "pipeline/pipeline/${TASK_ID}" 2>/dev/null \
    || aws logs get-log-events --log-group-name "$LOG_GROUP" \
         --log-stream-name "pipeline/pipeline/${TASK_ID}" --region "$REGION" \
         --query 'events[].message' --output text
echo "================"
echo
echo "exit code: ${EXIT_CODE}  (${REASON})"

# Propagate the container's exit code so this script fails when the run failed.
[[ "$EXIT_CODE" == "0" ]] || exit 1
