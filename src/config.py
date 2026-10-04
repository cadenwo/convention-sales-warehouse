"""
Configuration and secret resolution.

Credentials are never hardcoded and never committed to the repo. In AWS they
come from Secrets Manager; for local development they load from a `.env` file
(git-ignored — see .gitignore) or plain environment variables, so the pipeline
runs without any AWS involvement at all during development.

Expected secret shape (JSON) in Secrets Manager:

    {
      "SQUARE_ACCESS_TOKEN": "...",
      "SQUARE_ENVIRONMENT": "production",
      "PGHOST": "...",
      "PGPORT": "5432",
      "PGDATABASE": "sakuracon",
      "PGUSER": "...",
      "PGPASSWORD": "...",
      "S3_RAW_BUCKET": "sakuracon-sales-...",
      "S3_RAW_PREFIX": "sakuracon"
    }
"""

from __future__ import annotations

import functools
import json
import logging
import os

log = logging.getLogger(__name__)

SECRET_NAME_VAR = "PIPELINE_SECRET_NAME"


@functools.lru_cache(maxsize=4)
def _fetch_secret(secret_name: str) -> dict:
    """
    Read a JSON secret from AWS Secrets Manager.

    Cached because Fargate tasks are short-lived but may resolve the same
    secret several times, and Secrets Manager bills per API call.
    """
    import boto3

    region = os.environ.get("AWS_REGION", "us-east-1")
    client = boto3.client("secretsmanager", region_name=region)
    log.info("Fetching secret %s from Secrets Manager (%s)", secret_name, region)

    response = client.get_secret_value(SecretId=secret_name)
    return json.loads(response["SecretString"])


def _load_dotenv() -> None:
    """
    Populate os.environ from a `.env` file in the project root, if present.

    This only ever runs locally — a deployed Fargate task has no `.env` file
    baked into its image (see .dockerignore), so in production this is a no-op
    and PIPELINE_SECRET_NAME takes over below.
    """
    from pathlib import Path

    from dotenv import load_dotenv

    env_path = Path(__file__).resolve().parent.parent / ".env"
    if env_path.exists():
        load_dotenv(env_path)
        log.info("Loaded local .env from %s", env_path)


def get_settings() -> dict:
    """
    Resolve configuration, preferring Secrets Manager when PIPELINE_SECRET_NAME
    is set (the deployed path) and falling back to .env / the environment
    otherwise (the local-development path).
    """
    _load_dotenv()
    secret_name = os.environ.get(SECRET_NAME_VAR)

    if secret_name:
        settings = _fetch_secret(secret_name)
        source = f"Secrets Manager ({secret_name})"
    else:
        settings = {}
        source = "environment variables"

    # Environment always wins, so a local override can shadow a stored value
    # without editing the secret.
    for key in (
        "SQUARE_ACCESS_TOKEN", "SQUARE_ENVIRONMENT", "SQUARE_LOCATION_ID",
        "PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD", "PGSSLMODE",
        "S3_RAW_BUCKET", "S3_RAW_PREFIX", "AWS_REGION",
        "WAREHOUSE_TYPE", "REDSHIFT_IAM_ROLE",
    ):
        if os.environ.get(key):
            settings[key] = os.environ[key]

    log.info("Configuration resolved from %s", source)
    return settings


def require(settings: dict, *keys: str) -> None:
    """Fail fast with a clear message rather than a confusing auth error later."""
    missing = [k for k in keys if not settings.get(k)]
    if missing:
        raise SystemExit(
            f"Missing required configuration: {', '.join(missing)}. "
            f"Set them in the environment, or point {SECRET_NAME_VAR} at a "
            "Secrets Manager secret containing them."
        )
