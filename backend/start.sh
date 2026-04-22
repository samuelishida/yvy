#!/bin/sh
set -eu

if [ "${DEV:-0}" = "1" ]; then
  exec python /app/backend.py
fi

# Calculate worker count: 2 * CPU cores + 1, capped at 16
WORKERS=$(nproc)
WORKERS=$((2 * WORKERS + 1))
if [ $WORKERS -gt 16 ]; then
  WORKERS=16
fi

exec gunicorn \
  --bind 0.0.0.0:5000 \
  --workers $WORKERS \
  --timeout 120 \
  --graceful-timeout 30 \
  backend:app
