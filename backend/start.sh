#!/bin/sh
set -eu

if [ "${DEV:-0}" = "1" ]; then
  exec python /app/backend.py
fi

exec gunicorn \
  --bind 0.0.0.0:5000 \
  --workers 4 \
  --timeout 120 \
  --graceful-timeout 30 \
  backend:app
