#!/bin/sh
# Applies pending migrations, then starts the API. Set RUN_MIGRATIONS=false
# when migrations are run as a separate release step.
set -e
if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
  alembic upgrade head
fi
exec uvicorn app.main:app \
  --host "${HOST:-0.0.0.0}" \
  --port "${PORT:-8000}" \
  --proxy-headers \
  --forwarded-allow-ips="${FORWARDED_ALLOW_IPS:-127.0.0.1}" \
  --no-server-header \
  --timeout-graceful-shutdown 20
