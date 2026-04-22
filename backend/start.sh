#!/bin/sh
set -eu

if [ "${DEV:-0}" = "1" ]; then
  exec python /app/backend.py
fi

WORKERS=$(nproc)
WORKERS=$((2 * WORKERS + 1))
if [ $WORKERS -gt 16 ]; then
  WORKERS=16
fi

exec hypercorn backend:app \
  --bind 0.0.0.0:5000 \
  --workers $WORKERS \
  --worker-class asyncio \
  --keep-alive 120