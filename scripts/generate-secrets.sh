#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  echo ".env já existe. Nada a fazer."
  exit 0
fi

echo "Gerando .env com secrets aleatórios..."

generate_secret() {
  python3 -c "import secrets; print(secrets.token_urlsafe(${1:-32}))"
}

cat > "$ENV_FILE" <<EOF
MONGO_URI=
MONGO_DATABASE=terrabrasilis_data
MONGO_ROOT_USERNAME=root
MONGO_ROOT_PASSWORD=$(generate_secret 32)
MONGO_APP_USERNAME=yvy_app
MONGO_APP_PASSWORD=$(generate_secret 32)
MONGO_READONLY_USERNAME=yvy_readonly
MONGO_READONLY_PASSWORD=$(generate_secret 32)
BACKEND_URL=http://backend:5000
API_KEY=$(generate_secret 48)
AUTH_REQUIRED=1
CORS_ORIGINS=http://localhost:5001
RATE_LIMIT_REQUESTS=60
RATE_LIMIT_WINDOW_SECONDS=60
LOG_LEVEL=INFO
DEV=0
RUN_INGEST=0
EOF

echo ".env gerado em $ENV_FILE"
echo "⚠️  IMPORTANTE: Edite CORS_ORIGINS com o IP/domínio público da sua VM!"
