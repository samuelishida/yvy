# Yvy

Observabilidade ambiental para monitorar desmatamento e queimadas no Brasil.

Stack atual:
- Frontend: React + Express (proxy server-side)
- Backend: Quart + Hypercorn
- Banco principal: SQLite
- Cache/rate limit: Redis
- Dados geoespaciais: TerraBrasilis (PRODES) e FIRMS

## Requisitos

- Linux ou macOS
- Python 3.11+
- Node.js 18+
- Redis local ativo (padrao: `redis://localhost:6379/0`)
- Git

## Setup local

```bash
cp .env.example .env
make setup
```

`make setup` faz:
- cria venv Python em `$HOME/.local/share/yvy-venv` (fallback para FS sem symlink)
- instala deps backend (`backend/requirements.txt`)
- instala deps frontend (`frontend/package.json`)

## Run local

Subir tudo:

```bash
make run
```

Subir separado:

```bash
make backend
make frontend
```

Parar processos locais:

```bash
make stop
```

URLs locais:
- Frontend: http://127.0.0.1:5001
- Backend: http://127.0.0.1:5000

## Comandos Make

- `make setup` instala dependencias locais
- `make run` sobe backend + frontend
- `make backend` sobe so backend
- `make frontend` sobe so frontend
- `make stop` mata processos locais em background + portas 5000/5001
- `make test` roda script backend `test_sqlite_manual.py`
- `make sqlite-access` abre `.tables` do banco SQLite

## Ingestao de dados

Nao roda automatica no `make run`.

```bash
cd backend
python ingest_sqlite.py
```

## Endpoints

- `GET /health` (frontend)
- `GET /api/health`
- `GET /api/data`
- `GET /api/fires`
- `GET /api/weather/air-quality`
- `GET /api/weather/temperature`

## API key

Quando `AUTH_REQUIRED=1`, backend exige `X-API-Key` em rotas protegidas.
Frontend injeta chave server-side.

Exemplo chamada direta backend:

```bash
curl "http://127.0.0.1:5000/data?ne_lat=-10&ne_lng=-34&sw_lat=-34&sw_lng=-74" \
  -H "X-API-Key: $API_KEY"
```

## Arquitetura

```text
Browser -> Frontend (Express + React, :5001) -> Backend (Quart, :5000) -> SQLite
                                                          |
                                                          +-> Redis (rate limit/cache)
```

## Testes

Teste rapido via Make:

```bash
make test
```

Suite pytest backend:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt pytest pytest-asyncio
pytest backend/tests -v
```

> **Note:** `requirements-dev.txt` is stale (still lists MongoDB deps). Use `requirements.txt` + pytest/pytest-asyncio instead.

CI:
- `.github/workflows/ci.yml`
- `.gitlab-ci.yml`

## Deploy OCI (baremetal)

Deploy oficial: Terraform + Ansible, sem containers.

Fluxo:
1. Terraform cria VCN/subnet/regras/VM
2. Cloud-init prepara runtime (python/node/redis/sqlite)
3. Ansible aplica setup app e servicos systemd
4. Servicos ativos: `yvy-backend`, `yvy-frontend`

Arquivos referencia:
- `infra/README.md`
- `infra/main.tf`
- `ansible/playbook.yml`
- `.github/workflows/deploy-oci.yml`

## Variaveis de ambiente principais

- `API_KEY`
- `AUTH_REQUIRED`
- `CORS_ORIGINS`
- `LOG_LEVEL`
- `SQLITE_PATH`
- `REDIS_URL`
- `BACKEND_URL`
- `RATE_LIMIT_REQUESTS`
- `RATE_LIMIT_WINDOW_SECONDS`
- `DEV`
- `FIRMS_MAP_KEY`
- `NEWS_API_KEY`
- `WAQI_TOKEN`

Use `.env.example` como base (nota: `.env.example` ainda contem variaveis MongoDB legado).

## Troubleshooting rapido

- Porta ocupada (5000/5001): rode `make stop`, depois `make run`
- Trace gigante no shutdown com `RuntimeError: reentrant call inside _io.BufferedWriter.__repr__`:
  interrompa com `Ctrl+C`, rode `make stop`, suba de novo com `make run`

## Backup

```bash
./backup.sh
```

Saida padrao: `sqlite_backups/`

## Operacao

- `RUNBOOK.md`
- `PRODUCTION_READY_SUMMARY.md`
- `.github/workflows/GITHUB_SECRETS.md`

## Licenca

MIT. Veja `LICENSE`.

## Contato

Samuel Ishida:
- GitHub: https://github.com/samuelishida
- GitLab: https://gitlab.com/samuelishida
