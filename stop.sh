#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"

if command -v docker-compose >/dev/null 2>&1; then
  docker-compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down "$@"
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down "$@"
else
  echo "Docker Compose is required. Install docker-compose or the docker compose plugin." >&2
  exit 1
fi
