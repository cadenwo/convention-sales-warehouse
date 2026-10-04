#!/usr/bin/env bash
#
# Build the image, push it to ECR, and register a Fargate task definition.
#
#     ./infra/02_deploy_task.sh
#
# In steady state CI does the build and push (see .github/workflows/deploy.yml);
# this script exists so the first deployment can be made by hand, and so the
# whole thing can be reproduced without GitHub.
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

REPO_NAME="sakuracon-pipeline"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${REPO_NAME}"
FAMILY="sakuracon-pipeline"
LOG_GROUP="/ecs/sakuracon-pipeline"
SECRET_NAME="sakuracon/pipeline"

# Tag with the git commit rather than :latest. A mutable tag makes "which code
# produced this run?" unanswerable after the fact — the whole point of tagging
# by commit is that a CloudWatch log line can be traced back to a diff.
TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"

echo "Building ${IMAGE_URI}:${TAG}"

aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$REGISTRY"

# Fargate runs on linux/amd64. An Apple Silicon Mac builds arm64 by default,
# and the task fails at startup with an exec format error that gives no hint
# about architecture. --platform is not optional here.
docker build --platform linux/amd64 -t "${IMAGE_URI}:${TAG}" .
docker push "${IMAGE_URI}:${TAG}"

echo "Pushed ${IMAGE_URI}:${TAG}"

# ---------------------------------------------------------------------------
# Task definition
# ---------------------------------------------------------------------------
cat > /tmp/sakuracon-task-def.json <<JSON
{
  "family": "${FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/sakuracon-task-execution-role",
  "taskRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/sakuracon-task-role",
  "runtimePlatform": {
    "cpuArchitecture": "X86_64",
    "operatingSystemFamily": "LINUX"
  },
  "containerDefinitions": [
    {
      "name": "pipeline",
      "image": "${IMAGE_URI}:${TAG}",
      "essential": true,
      "environment": [
        {"name": "PIPELINE_SECRET_NAME", "value": "${SECRET_NAME}"},
        {"name": "AWS_REGION", "value": "${REGION}"},
        {"name": "LOG_LEVEL", "value": "INFO"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "pipeline"
        }
      }
    }
  ]
}
JSON

# Only the secret's *name* is passed as an environment variable — never its
# contents. config.py resolves it at runtime using the task role, so the
# credentials never appear in the task definition, in the console, or in
# anything `describe-task-definition` would return.

REVISION="$(aws ecs register-task-definition \
    --cli-input-json file:///tmp/sakuracon-task-def.json \
    --region "$REGION" \
    --query 'taskDefinition.revision' --output text)"

rm -f /tmp/sakuracon-task-def.json

echo
echo "Registered ${FAMILY}:${REVISION}"
echo
echo "Run it once by hand to verify:"
echo "  ./infra/03_run_once.sh --backfill --init"
