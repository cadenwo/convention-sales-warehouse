#!/usr/bin/env bash
#
# Create the daily EventBridge schedule that runs the pipeline unattended.
#
#     ./infra/04_schedule.sh
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CLUSTER="sakuracon-cluster"
FAMILY="sakuracon-pipeline"
SCHEDULE_NAME="sakuracon-daily"
SCHEDULER_ROLE="sakuracon-scheduler-role"

# 06:00, read in the timezone set below — not UTC. Late enough that the
# previous day is closed out, early enough that a failure is visible before the
# working day starts.
#
# An earlier version of this file said "13:00 UTC = 06:00 Pacific" and set the
# hour to 13, which was correct only if the schedule ran in UTC. It does not:
# --schedule-expression-timezone is America/Los_Angeles, so the hour is read
# locally and the job fired at 1pm. The timezone is deliberate — it keeps 06:00
# meaning 06:00 across daylight saving, which a fixed UTC hour would not — but
# it means the cron hour must be local too.
CRON="cron(0 6 * * ? *)"

VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" \
    --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
SUBNET_ID="$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[0].SubnetId' --output text)"
SG_ID="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" Name=group-name,Values=default \
    --query 'SecurityGroups[0].GroupId' --output text)"

# EventBridge Scheduler needs its own role to call ecs:RunTask on your behalf,
# and to pass the task's two roles to ECS. That iam:PassRole is the permission
# that actually matters: without a condition it would let anything holding this
# role hand *any* role to ECS.
if ! aws iam get-role --role-name "$SCHEDULER_ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$SCHEDULER_ROLE" \
        --assume-role-policy-document '{
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "scheduler.amazonaws.com"},
            "Action": "sts:AssumeRole"
          }]
        }' >/dev/null
    echo "Created ${SCHEDULER_ROLE}"
fi

aws iam put-role-policy --role-name "$SCHEDULER_ROLE" \
    --policy-name sakuracon-scheduler-permissions \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Sid\": \"RunOnlyThisTaskFamily\",
          \"Effect\": \"Allow\",
          \"Action\": \"ecs:RunTask\",
          \"Resource\": \"arn:aws:ecs:${REGION}:${ACCOUNT_ID}:task-definition/${FAMILY}:*\"
        },
        {
          \"Sid\": \"PassOnlyTheTasksOwnRoles\",
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

TARGET="$(python3 -c "
import json, sys
region, account, cluster, subnet, sg = sys.argv[1:6]
print(json.dumps({
    'Arn': f'arn:aws:ecs:{region}:{account}:cluster/{cluster}',
    'RoleArn': f'arn:aws:iam::{account}:role/sakuracon-scheduler-role',
    'EcsParameters': {
        'TaskDefinitionArn': f'arn:aws:ecs:{region}:{account}:task-definition/sakuracon-pipeline',
        'LaunchType': 'FARGATE',
        'NetworkConfiguration': {
            'awsvpcConfiguration': {
                'Subnets': [subnet],
                'SecurityGroups': [sg],
                'AssignPublicIp': 'ENABLED',
            }
        },
    },
    'Input': json.dumps({
        'containerOverrides': [
            {'name': 'pipeline', 'command': ['--lookback-hours', '24']}
        ]
    }),
    # If the scheduler can't start the task (RunTask throttled or rejected), it
    # retries twice within the hour, then gives up. A run that starts and then
    # fails is not retried; rerun it with infra/03_run_once.sh --backfill.
    'RetryPolicy': {'MaximumRetryAttempts': 2, 'MaximumEventAgeInSeconds': 3600},
}))
" "$REGION" "$ACCOUNT_ID" "$CLUSTER" "$SUBNET_ID" "$SG_ID")"

if aws scheduler get-schedule --name "$SCHEDULE_NAME" --region "$REGION" >/dev/null 2>&1; then
    ACTION=update-schedule
else
    ACTION=create-schedule
fi

# IAM is eventually consistent. A role created a second ago is not yet visible
# to other services, and EventBridge rejects it with "must allow AWS EventBridge
# Scheduler to assume the role" — which reads like a malformed trust policy but
# is really a race. Retry rather than making the operator run the script twice.
for attempt in 1 2 3 4 5 6; do
    if ERR="$(aws scheduler "$ACTION" \
        --name "$SCHEDULE_NAME" \
        --region "$REGION" \
        --schedule-expression "$CRON" \
        --schedule-expression-timezone "America/Los_Angeles" \
        --flexible-time-window '{"Mode": "OFF"}' \
        --target "$TARGET" 2>&1 >/dev/null)"; then
        break
    fi

    if grep -q "must allow AWS EventBridge Scheduler to assume the role" <<<"$ERR" \
       && [[ $attempt -lt 6 ]]; then
        echo "IAM role not propagated yet; retrying in 10s (${attempt}/6)"
        sleep 10
        continue
    fi

    echo "$ERR" >&2
    exit 1
done

echo "Schedule ${SCHEDULE_NAME} set: ${CRON} (America/Los_Angeles)"
echo
aws scheduler get-schedule --name "$SCHEDULE_NAME" --region "$REGION" \
    --query '{name:Name,state:State,cron:ScheduleExpression,tz:ScheduleExpressionTimezone}'
