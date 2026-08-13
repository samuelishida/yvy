# References — similar code in repo to learn from

## Ingestion (Inc 1)
- `scripts/data/download_sinaflor_auth.py` — o template exato: CKAN → DB
  dedicado, `<out>.tmp` + `os.replace` atômico, `--today`/`--force`/`--window`,
  descoberta de schema em runtime.
- `scripts/deploy/sync-sinaflor.sh` — scp do DB dedicado para prod + verificação.
- `backend-lua/app/lookups/sinaflor_lookup.lua` — lookup runtime com
  `PRAGMA query_only=ON`, `is_loaded()` memo 60s, pré-carrega em memória.

## Precompute + version_key (Inc 2)
- `backend-lua/app/lookups/car_prodes.lua` — lookup + writer offline,
  `version_key` invalidação (`:120-140`).
- `backend-lua/app/lookups/car_protected_overlap.lua` — Monte-Carlo overlap,
  `throttled_upsert` com `redis.setnx`.
- `backend-lua/tools/warm_car_prodes.lua` — subprocess destacado de precompute.
- `backend-lua/Makefile` — alvos `warm-car-prodes`, `warm-car-protected`.

## Batch job + detached subprocess (Inc 3)
- `backend-lua/app/routes/fires.lua:520-580` — `trigger_*` spawna via
  `nohup lua5.1 "<script>" &` + lock `redis.setnx`.
- `backend-lua/tools/classify_fires.lua` — require-able (`is_main` guard),
  escreve `last_run` sentinel.
- `backend-lua/app/utils.lua:98` — `parse_csv` reutilizável (body CSV raw).
- `backend-lua/app/server.lua:42,121-132` — `MAX_REQUEST_SIZE` (env) +
  `parse_request` lê body via `Content-Length`.
- `ansible/templates/yvy-nginx.conf.j2:65-66` — `location /api/` proxy direto
  ao Lua :5000; **sem `client_max_body_size`** (default nginx 1MB = gate real
  de upload em prod). Setar `client_max_body_size` aqui.
- `backend-lua/yvy-server.c:76-77` — `MAX_REQUEST_SIZE`/`MAX_RESPONSE_SIZE`
  (gate dev/local apenas; em prod só serve estáticos).

## PDF (Inc 4)
- `backend-lua/app/server.lua:200` — MIME `application/pdf` já mapeado.
- `scripts/requirements.txt` — onde adicionar `reportlab`.

## Frontend (Inc 5)
- `frontend/src/App.js` — rotas lazy.
- `frontend/src/components/Dashboard/useCardData.js` + `CardShell.js` —
  fetch + estados + export.
- `frontend/src/utils/apiCache.js` — `cachedFetch`/`invalidateApiCache`.
- `frontend/src/i18n.js` — seção `risk:` em pt/en.
- `frontend/src/index.css` — design tokens.

## Scheduled job + systemd timer (Inc 6)
- `ansible/templates/yvy-deter-daily.service.j2` + `.timer.j2` — template de
  job agendado.
- `ansible/playbook.yml` — 3 tasks (template service, template timer, enable).
- `scripts/data/deter_daily.sh` — wrapper bash idempotente.
- `backend-lua/app/routes/alerts.lua` — modelo de severidade existente.
