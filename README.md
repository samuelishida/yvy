# Yvy

Aplicativo de observabilidade ambiental para monitorar o desmatamento no Brasil, utilizando Flask, Leaflet, MongoDB e dados do TerraBrasilis (PRODES).

## Pré-requisitos

- Docker e Docker Compose
- Python 3.13+ (apenas para rodar testes localmente)
- Git

## Instalação e execução

1. Clone o repositório:
   ```bash
   git clone https://gitlab.com/samuelishida/yvy.git
   cd yvy
   ```

2. Configure as variáveis de ambiente:
   ```bash
   cp .env.dev.example .env
   # Para produção, use .env.prod.example como base
   ```

3. Suba todos os serviços:
   ```bash
   docker-compose up --build
   ```

O frontend estará disponível em `http://localhost:5001` e a API do backend em `http://localhost:5000`.
O MongoDB fica acessível apenas dentro da rede Docker por padrão.

### Ingestão de dados

A ingestão dos dados do TerraBrasilis não é executada automaticamente na inicialização. Para processar os arquivos TIF e popular o MongoDB, execute o script de ingestão separado:

```bash
docker-compose exec backend python ingest.py
```

## Uso

- `/` — Página inicial
- `/dashboard` — Visualização tabular dos dados de desmatamento
- `/map` — Mapa interativo (Leaflet) com sobreposição dos dados
- `/health` — Endpoint de health check do frontend e do backend

### Autenticação da API

O endpoint `/data` exige uma chave de API quando `AUTH_REQUIRED=1`.

```bash
curl "http://localhost:5000/data?ne_lat=-10&ne_lng=-34&sw_lat=-34&sw_lng=-74" \
  -H "X-API-Key: $API_KEY"
```

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

## Testes

Os testes usam `pytest` com `mongomock` (sem dependência de MongoDB real) para o backend, além de smoke tests para as rotas do frontend.

```bash
# Crie e ative o ambiente virtual (uma única vez)
python3 -m venv .venv
source .venv/bin/activate
.venv/bin/pip3 install -r backend/requirements-dev.txt

# Execute os testes
cd backend
../.venv/bin/pytest -v
```

O repositório também inclui CI em [`.github/workflows/ci.yml`](/media/samuel/Shared/Code/Yvy/.github/workflows/ci.yml), que valida:

- suíte de testes do backend
- compilação dos arquivos Python
- sintaxe dos scripts shell
- sintaxe do `mongo-init.js`

## Segurança

- **Nunca commitar `.env`** — use os templates `.env.dev.example`, `.env.prod.example` ou `.env.example`
- **Substitua os placeholders** por segredos fortes gerados com `python -c "import secrets; print(secrets.token_urlsafe(24))"`
- **Crie um `.env`** antes de subir os containers: `cp .env.dev.example .env` ou `cp .env.prod.example .env`
- **Defina `API_KEY`** antes de expor a API fora do ambiente local
- **O MongoDB não é publicado em `27017`** por padrão; use `make mongo-access` ou `docker-compose exec mongo ...`
- **Backup automático**: execute `./backup.sh` manualmente ou agende com cron
- **Headers de segurança** são aplicados no frontend e backend (`CSP`, `X-Frame-Options`, `nosniff`)

## Operação

- Runbook operacional: [RUNBOOK.md](/media/samuel/Shared/Code/Yvy/RUNBOOK.md)
- Template local: [`.env.dev.example`](/media/samuel/Shared/Code/Yvy/.env.dev.example)
- Template de produção: [`.env.prod.example`](/media/samuel/Shared/Code/Yvy/.env.prod.example)
- Workflow de CI: [`.github/workflows/ci.yml`](/media/samuel/Shared/Code/Yvy/.github/workflows/ci.yml)
- Script de backup: [backup.sh](/media/samuel/Shared/Code/Yvy/backup.sh)

## Estrutura do Projeto

```
yvy/
├── backend/
│   ├── backend.py          # API Flask (rotas /  e /data)
│   ├── ingest.py           # Script de ingestão de dados TIF
│   ├── requirements.txt    # Dependências de produção
│   ├── requirements-dev.txt# Dependências de desenvolvimento/teste
│   ├── pytest.ini          # Configuração do pytest
│   ├── Dockerfile
│   └── tests/
│       └── test_api.py     # Suite de testes da API
├── frontend/
│   ├── frontend.py         # Servidor Flask (templates Jinja2)
│   ├── templates/          # HTML (index, dashboard, map)
│   ├── static/             # CSS e JavaScript
│   └── Dockerfile
├── .env.example            # Variáveis de ambiente (template)
├── .env.dev.example        # Template local/desenvolvimento
├── .env.prod.example       # Template produção
├── .github/workflows/ci.yml# Pipeline de validação
├── docker-compose.yml
├── mongo-init.js           # Script de inicialização do MongoDB
├── RUNBOOK.md              # Procedimentos operacionais
├── backup.sh               # Backup lógico do MongoDB
└── Makefile
```

## Variáveis de Ambiente

| Variável       | Padrão                                              | Descrição                          |
|----------------|-----------------------------------------------------|------------------------------------|
| `MONGO_URI`    | vazio                                               | URI opcional. Se vazio, o backend monta a conexão a partir das credenciais abaixo |
| `MONGO_DATABASE` | `terrabrasilis_data`                              | Banco principal da aplicação |
| `MONGO_ROOT_USERNAME` | `root`                                       | Usuário root usado apenas para administração |
| `MONGO_ROOT_PASSWORD` | vazio                                     | Senha root do MongoDB. Obrigatória no `.env` |
| `MONGO_APP_USERNAME` | `yvy_app`                                     | Usuário usado pelo backend |
| `MONGO_APP_PASSWORD` | vazio                                      | Senha do usuário do backend. Obrigatória no `.env` |
| `MONGO_READONLY_USERNAME` | `yvy_readonly`                          | Usuário somente leitura |
| `MONGO_READONLY_PASSWORD` | vazio                                 | Senha do usuário somente leitura. Obrigatória no `.env` |
| `BACKEND_URL`  | `http://backend:5000`                               | URL interna do backend             |
| `API_KEY`      | vazio                                               | Chave exigida pelo endpoint `/data`. Obrigatória quando `AUTH_REQUIRED=1` |
| `AUTH_REQUIRED`| `1`                                                 | Exige API key no backend quando ligado |
| `CORS_ORIGINS` | `http://localhost:5001,http://127.0.0.1:5001`       | Origens permitidas pelo CORS       |
| `RATE_LIMIT_REQUESTS` | `60`                                         | Limite de requisições por janela para `/data` |
| `RATE_LIMIT_WINDOW_SECONDS` | `60`                                  | Janela usada pelo rate limit |
| `LOG_LEVEL`    | `INFO`                                              | Nível do logging estruturado |
| `DEV`          | `0`                                                 | `1` para rodar o servidor Flask dentro do container |
| `RUN_INGEST`   | `0`                                                 | Reservado para ingestão automatizada |

### 🔴 Importante: Segurança

- **Nunca commitar `.env`** — use os templates `.env.dev.example`, `.env.prod.example` ou `.env.example`
- **Substitua os placeholders** por segredos fortes gerados com `python -c "import secrets; print(secrets.token_urlsafe(24))"`
- **Crie um `.env`** antes de subir os containers: `cp .env.dev.example .env` ou `cp .env.prod.example .env`
- **Defina `API_KEY`** antes de liberar acesso ao endpoint `/data`

## Makefile

| Comando               | Descrição                                          |
|-----------------------|----------------------------------------------------|
| `make run`            | Sobe todos os serviços                             |
| `make build`          | Para e reconstrói frontend e backend               |
| `make build-backend`  | Para e reconstrói somente o backend                |
| `make build-frontend` | Para e reconstrói somente o frontend               |
| `make rebuild`        | Derruba, reconstrói e sobe tudo                    |
| `make rebuild-backend`| Derruba, reconstrói e sobe somente o backend       |
| `make rebuild-frontend`| Derruba, reconstrói e sobe somente o frontend     |
| `make stop`           | Para todos os serviços                             |
| `make clean`          | Remove volumes persistentes e reconstrói           |
| `make mongo-access`   | Abre o shell do MongoDB                            |

## Contribuindo

1. Faça um fork do projeto.
2. Crie uma branch para sua feature (`git checkout -b feature/nova-feature`).
3. Commit suas alterações (`git commit -m 'Adiciona nova feature'`).
4. Faça push para a branch (`git push origin feature/nova-feature`).
5. Abra um Pull Request.

## Licença

MIT — veja [LICENSE](LICENSE) para detalhes.

## Contato

Samuel Ishida — [GitLab](https://gitlab.com/samuelishida)

Sinta-se à vontade para abrir uma issue se encontrar algum problema ou tiver sugestões.
