#!/bin/sh
set -eu

if [ "${DEV:-0}" = "1" ]; then
  exec python /app/frontend.py
fi

exec gunicorn \
  --bind 0.0.0.0:5001 \
  --workers 2 \
  --timeout 120 \
  --graceful-timeout 30 \
  frontend:app
