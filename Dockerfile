# =============================================================================
# Sakura-Con sales pipeline
#
# Multi-stage build. The builder compiles wheels into a virtualenv; the runtime
# image copies that virtualenv and nothing else, so gcc and the libpq headers
# never ship. Image size matters on Fargate because every scheduled run pulls
# the image from ECR before the task can start.
# =============================================================================

# ---------- builder ----------------------------------------------------------
FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Needed to compile psycopg2; neither is needed at runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# A virtualenv at a fixed path, rather than `pip install --user`. User-site
# installs resolve against $HOME, which changes when the runtime stage switches
# users — a venv on PATH has no such ambiguity.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /build
COPY requirements.txt .
RUN pip install --upgrade pip && pip install -r requirements.txt


# ---------- runtime ----------------------------------------------------------
FROM python:3.11-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:$PATH" \
    DBT_PROFILES_DIR=/app/dbt

# libpq5 is the runtime shared library psycopg2 links against — the headers and
# compiler stay behind in the builder.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash pipeline

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=pipeline:pipeline src/     ./src/
COPY --chown=pipeline:pipeline scripts/ ./scripts/
COPY --chown=pipeline:pipeline sql/     ./sql/
COPY --chown=pipeline:pipeline dbt/     ./dbt/

# dbt writes target/ and logs/ while it runs and must be able to do so as a
# non-root user.
RUN mkdir -p /app/dbt/target /app/dbt/logs && chown -R pipeline:pipeline /app/dbt

# A pipeline that reads an API and writes to a warehouse has no reason to be
# root inside its own filesystem.
USER pipeline

# Fail the build here rather than at 3am on a scheduled run.
RUN python -c "import square, psycopg2, boto3, tenacity, dotenv" \
    && dbt --version \
    && python -c "import sys; sys.path.insert(0, 'src'); import square_extract, config"

ENTRYPOINT ["python", "scripts/run_pipeline.py"]

# Default to the incremental window; EventBridge overrides this per task when a
# backfill or a longer catch-up is needed.
CMD ["--lookback-hours", "24"]
