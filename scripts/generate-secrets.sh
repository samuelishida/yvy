#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  echo ".env já existe. Nada a fazer."
  exit 0
fi

echo "Gerando .env com secrets aleatórios..."

# Cross-platform Python detection
PYTHON_CMD=""
for cmd in python3 python py; do
  if command -v "$cmd" &>/dev/null; then
    major=$("$cmd" -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo 0)
    if [ "$major" -ge 3 ]; then
      PYTHON_CMD="$cmd"
      break
    fi
  fi
done
if [ -z "$PYTHON_CMD" ]; then
  echo "ERROR: Python 3 not found."
  exit 1
fi

generate_secret() {
  "$PYTHON_CMD" -c "import secrets; print(secrets.token_urlsafe(${1:-32}))"
}

cat > "$ENV_FILE" <<EOF
API_KEY=$(generate_secret 48)
AUTH_REQUIRED=1
CORS_ORIGINS=http://localhost:5001
RATE_LIMIT_REQUESTS=60
RATE_LIMIT_WINDOW_SECONDS=60
LOG_LEVEL=INFO
DEV=0
RUN_INGEST=0
NEWS_API_KEY=
FIRMS_MAP_KEY=
WAQI_TOKEN=demo
SQLITE_PATH=/opt/yvy/backend/data/yvy.db
REDIS_URL=redis://localhost:6379/0
BACKEND_URL=http://127.0.0.1:5000
EOF

echo ".env gerado em $ENV_FILE"
echo "⚠️  IMPORTANTE: Edite CORS_ORIGINS com o IP/domínio público da sua VM!"
echo "⚠️  Adicione NEWS_API_KEY e FIRMS_MAP_KEY para funcionalidade completa."
