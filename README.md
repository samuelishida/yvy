# Yvy

Aplicativo de observabilidade ambiental para monitorar o desmatamento no Brasil, utilizando **React** (frontend), **Express** (proxy/servidor), **Flask** (backend API), **MongoDB** e **Redis**, com dados do TerraBrasilis (PRODES).

## Pré-requisitos

- Docker e Docker Compose (v2)
- Git

## Instalação e execução

1. Clone o repositório:
   ```bash
   git clone https://github.com/samuelishida/yvy.git
   cd yvy
   ```

2. Configure as variáveis de ambiente:
   ```bash
   cp .env.dev.example .env
   # Para produção, use .env.prod.example como base
   ```

3. Suba todos os serviços:
   ```bash
   docker compose up --build
   ```

O frontend estará disponível em `http://localhost:5001`. A API do backend **não é exposta publicamente** — todo acesso passa pelo proxy Express, que injeta a API key server-side. O MongoDB e o Redis ficam acessíveis apenas dentro da rede Docker.

### Ingestão de dados

A ingestão dos dados do TerraBrasilis não é executada automaticamente na inicialização. Para processar os arquivos TIF e popular o MongoDB, execute:

```bash
docker compose exec backend python ingest.py
```

## Uso

- `/` — **Home** com seletor de mapas (Desmatamento, Qualidade do Ar, Temperatura, Tempestades, Florestas Globais, Nível do Mar, Incêndios NASA)
- `/dashboard` — **Dashboard** com estatísticas e gráfico de distribuição por categoria
- `/news` — **Feed de notícias** ambientais (via NewsAPI)
- `/health` — Endpoint de health check do frontend e do backend

### Autenticação da API

Quando `AUTH_REQUIRED=1`, o backend exige uma chave de API no endpoint `/data`. O proxy Express no frontend injeta `X-API-Key` server-side, sem expor a chave ao navegador. Para chamadas diretas:

```bash
curl "http://localhost:5000/data?ne_lat=-10&ne_lng=-34&sw_lat=-34&sw_lng=-74" \
  -H "X-API-Key: $API_KEY"
```

> Em produção, o backend não é exposto em porta pública — use `docker compose exec` ou `make mongo-access` para acesso direto.

### Acessando o MongoDB diretamente

```bash
make mongo-access
```

Dentro do shell do MongoDB:
```js
show dbs
use terrabrasilis_data
db.deforestation_data.countDocuments({})
```

## Arquitetura

```
┌────────────┐       ┌─────────────┐       ┌──────────┐
│  Navegador │──────▶│   Frontend  │──────▶│  Backend │
│  :5001     │  HTTP │  (Express + │  API   │  (Flask +│
│            │◀──────│   React)    │◀──────│  Gunicorn)│
└────────────┘       └─────────────┘       └────┬─────┘
                                                  │
                                           ┌──────┴──────┐
                                           │             │
                                        ┌──┴──┐   ┌────┴────┐
                                        │Mongo│   │  Redis   │
                                        │ DB  │   │(rate     │
                                        └─────┘   │ limiting)│
                                                  └──────────┘
```

- **Frontend**: Express serve o build React e faz proxy de `/api/*` para o backend, injetando a API key server-side.
- **Backend**: Flask+Gunicorn com rate limiting via Redis, autenticação por API key, logging estruturado JSON.
- **MongoDB**: Autenticado (usuários `yvy_app` e `yvy_readonly` criados pelo init script).
- **Redis**: Compartilha estado de rate limiting entre os workers do Gunicorn.

## Testes

Os testes usam `pytest` com `mongomock` (sem dependência de MongoDB real) para o backend.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements-dev.txt
cd backend && ../.venv/bin/pytest -v
```

O repositório também inclui CI em [`.github/workflows/ci.yml`](.github/workflows/ci.yml), que valida:

- Suíte de testes do backend (`pytest`)
- Compilação de todos os fontes Python (`py_compile`)
- Sintaxe dos scripts shell (`sh -n`)
- Sintaxe do `mongo-init.js` (`node -c`)

## Segurança

- **MongoDB autenticado**: Usuários `yvy_app` (read/write) e `yvy_readonly` criados automaticamente via `mongo-init.js`
- **Backend não exposto publicamente**: Usa `expose` em vez de `ports` no docker-compose
- **API key nunca exposta ao navegador**: O proxy Express injeta `X-API-Key` server-side
- **Rate limiting via Redis**: Compartilhado entre workers, com allowlist de proxies confiáveis (`TRUSTED_PROXIES`)
- **Headers de segurança**: CSP, X-Frame-Options, nosniff aplicados no frontend e backend
- **Nunca commitar `.env`** — use os templates `.env.dev.example`, `.env.prod.example` ou `.env.example`
- **Substitua os placeholders** por segredos fortes gerados com `python -c "import secrets; print(secrets.token_urlsafe(24))"`
- **Backup automático**: execute `./backup.sh` manualmente ou agende com cron

## Operação

| Item | Link |
|------|------|
| Runbook operacional | [RUNBOOK.md](RUNBOOK.md) |
| Resumo de hardening | [PRODUCTION_READY_SUMMARY.md](PRODUCTION_READY_SUMMARY.md) |
| Template de desenvolvimento | [`.env.dev.example`](.env.dev.example) |
| Template de produção | [`.env.prod.example`](.env.prod.example) |
| Pipeline de CI | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) |
| Script de backup | [backup.sh](backup.sh) |

## Estrutura do Projeto

```
yvy/
├── backend/
│   ├── backend.py           # API Flask (rotas, auth, rate limit, logging)
│   ├── ingest.py            # Script de ingestão de dados TIF/QML
│   ├── news.py              # Integração NewsAPI para notícias ambientais
│   ├── requirements.txt     # Dependências de produção
│   ├── requirements-dev.txt  # Dependências de desenvolvimento/teste
│   ├── pytest.ini            # Configuração do pytest
│   ├── Dockerfile            # Imagem Python 3.13 com gunicorn
│   ├── start.sh              # Entrypoint: dev server ou gunicorn dinâmico
│   ├── tests/
│   │   └── test_api.py       # Suíte de testes da API
│   ├── .dockerignore
│   └── prodes_brasil_2023.*  # Base PRODES (TIF+QML)
├── frontend/
│   ├── Dockerfile             # Multi-stage: build React + Express server
│   ├── package.json           # Dependências Node.js (React, Express, etc.)
│   ├── server.js              # Express server com proxy para backend
│   ├── .dockerignore
│   ├── public/                # HTML base
│   └── src/
│       ├── index.js           # Entry point React
│       ├── index.css          # Estilos globais
│       ├── App.js             # Rotas e layout
│       ├── App.css            # Estilos do app
│       ├── setupProxy.js      # Proxy dev para backend local
│       └── components/
│           ├── Navbar.js/css  # Navegação
│           ├── Home.js/css    # Seletor de mapas
│           ├── Dashboard.js/css # Estatísticas e gráfico
│           └── News.js/css    # Feed de notícias ambientais
├── main.py                    # Integrações: OpenWeatherMap, WAQI, NASA EarthData, IQAir
├── gpw.py                     # Integração Global Forest Watch
├── .env.example               # Variáveis de ambiente (template genérico)
├── .env.dev.example            # Template local/desenvolvimento
├── .env.prod.example          # Template produção
├── .dockerignore
├── .github/workflows/ci.yml   # Pipeline de validação
├── docker-compose.yml         # Orquestração: mongo, redis, backend, frontend
├── mongo-init.js              # Script de inicialização do MongoDB (usuários)
├── RUNBOOK.md                 # Procedimentos operacionais
├── PRODUCTION_READY_SUMMARY.md # Resumo de hardening de produção
├── backup.sh                  # Backup lógico do MongoDB
├── build.sh                   # Script de build conveniente
├── run.sh                     # Script de execução conveniente
└── Makefile                   # Atalhos comuns (make run, make build, etc.)
```

## Variáveis de Ambiente

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `MONGO_URI` | vazio | URI completa. Se vazio, o backend monta a partir das credenciais abaixo |
| `MONGO_DATABASE` | `terrabrasilis_data` | Banco principal da aplicação |
| `MONGO_ROOT_USERNAME` | `root` | Usuário root do MongoDB (admin) |
| `MONGO_ROOT_PASSWORD` | vazio | Senha root. **Obrigatória no `.env`** |
| `MONGO_APP_USERNAME` | `yvy_app` | Usuário usado pelo backend (read/write) |
| `MONGO_APP_PASSWORD` | vazio | Senha do app. **Obrigatória no `.env`** |
| `MONGO_READONLY_USERNAME` | `yvy_readonly` | Usuário somente leitura |
| `MONGO_READONLY_PASSWORD` | vazio | Senha do readonly. **Obrigatória no `.env`** |
| `BACKEND_URL` | `http://backend:5000` | URL interna do backend |
| `API_KEY` | vazio | Chave exigida pelo endpoint `/data` quando `AUTH_REQUIRED=1` |
| `AUTH_REQUIRED` | `0` | Exige API key no backend quando `1` |
| `CORS_ORIGINS` | `http://localhost:5001,...` | Origens permitidas pelo CORS |
| `NEWS_API_KEY` | vazio | Chave da NewsAPI (notícias ambientais) |
| `RATE_LIMIT_REQUESTS` | `60` | Limite de requisições por janela |
| `RATE_LIMIT_WINDOW_SECONDS` | `60` | Janela do rate limit |
| `TRUSTED_PROXIES` | `172.16.0.0/12,192.168.0.0/16,10.0.0.0/8` | Proxies confiáveis para X-Forwarded-For |
| `REDIS_URL` | `redis://redis:6379/0` | URL do Redis para rate limiting |
| `LOG_LEVEL` | `INFO` | Nível do logging estruturado |
| `DEV` | `0` | `1` para rodar Flask dev server dentro do container |
| `RUN_INGEST` | `0` | Reservado para ingestão automatizada |

## Makefile

| Comando | Descrição |
|---------|-----------|
| `make run` | Sobe todos os serviços |
| `make build` | Para e reconstrói frontend e backend |
| `make build-backend` | Para e reconstrói somente o backend |
| `make build-frontend` | Para e reconstrói somente o frontend |
| `make rebuild` | Derruba, reconstrói e sobe tudo |
| `make rebuild-backend` | Derruba, reconstrói e sobe somente o backend |
| `make rebuild-frontend` | Derruba, reconstrói e sobe somente o frontend |
| `make stop` | Para todos os serviços |
| `make clean` | Remove volumes persistentes e reconstrói |
| `make mongo-access` | Abre o shell do MongoDB |

## Contribuindo

1. Faça um fork do projeto
2. Crie uma branch: `git checkout -b feature/minha-nova-feature`
3. Commit: `git commit -m 'Adiciona minha nova feature'`
4. Push: `git push origin feature/minha-nova-feature`
5. Abra um Pull Request

## Licença

MIT — veja [LICENSE](LICENSE) para detalhes.

## Contato

Samuel Ishida — [GitHub](https://github.com/samuelishida) · [GitLab](https://gitlab.com/samuelishida)

Sinta-se à vontade para abrir uma issue se encontrar algum problema ou tiver sugestões.