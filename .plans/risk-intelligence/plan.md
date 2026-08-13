# Yvy Risk Intelligence — Camada de Decisão Empresarial

> STATUS: implemented — todos os 6 incrementos concluídos e verificados
> (busted 278/0, luac -p, sh -n, py_compile, npm run build).

## Context

O MapBiomas Alerta (e o "Meu MapBiomas" da Coleção 11) oferece dados de
desmatamento validados, laudos técnicos e API **de graça**. O Yvy não pode
competir na camada de visualização/dashboard/análise territorial genérica —
essa trincheira morreu. O gap defensável (`.agents/yvy_gap_analysis.md`) é a
**camada de decisão empresarial**:

1. **Análise em lote de fornecedores** — upload CSV (CNPJ + coordenadas/CAR) →
   score de risco 0–100 → laudo → recomendação de ação.
2. **Monitoramento contínuo de fornecedores** — alerta contextualizado quando
   um fornecedor da cadeia tem novo desmatamento.
3. **Laudo profissional auditável** — PDF que o compliance anexa à due
   diligence / EUDR.

O MapBiomas é o **FLOOR, não o teto**: o Yvy **usa** o MapBiomas Alerta como
fonte de dados e adiciona a camada de decisão por cima.

**Restrições herdadas do código** (verificadas em exploração):
- Backend é **Lua 5.1, loop copas single-threaded** — nenhum cruzamento
  espacial denso nem geração de PDF no loop. Trabalho pesado roda em
  **subprocesso destacado** (`tools/*.lua` + `nohup` + lock Redis `setnx`).
- **O gate real de upload em produção é o nginx** (`ansible/templates/
  yvy-nginx.conf.j2` — source of truth): `/api/*` vai **direto ao Lua :5000**,
  bypassando o C server. O nginx **não configura `client_max_body_size`** →
  default **1MB** → qualquer body >1MB recebe 413 do nginx antes de chegar ao
  Lua. O `server.lua`'s `MAX_REQUEST_SIZE` (env-configurable, 1MB default) é
  o segundo gate. O proxy C `yvy-server.c` (1MB req / 2MB resp caps) só é gate
  em **dev/local** (sem nginx) — em prod serve só arquivos estáticos.
- Rotas **POST já existem** em `main.lua` (`/api/fires/sync`, `/api/admin/*`,
  `/api/news/refresh`); `server.lua` já lê body via `Content-Length`. O
  trabalho novo é **parsing multipart/CSV de body**, não "adicionar POST".
- Datasets externos usam **DB SQLite dedicado** (`car.db`, `sinaflor_auth.db`)
  com swap atômico `os.replace` + leitores `PRAGMA query_only=ON` — nunca
  tocam o `yvy.db` vivo.
- **Precompute + invalidação `version_key`** é o padrão estabelecido para
  análise por-propriedade (`car_prodes`, `car_protected_overlap`).
- Modelo de severidade já existe (`deter_car_alerts.severity` =
  maximo/alto/medio/baixo).
- **Não existe** PDF, email/webhook, upload de arquivo, nem sistema de
  usuário/auth (só API key compartilhada).
- **Gotcha de subprocesso destacado**: o proxy C avisa que subprocessos
  spawnados pelo Lua herdam o fd do socket do cliente — EOF só chega quando o
  filho sai. Jobs `nohup` e o renderer de PDF precisam **fechar/redirecionar
  o fd herdado** para a resposta retornar cedo.

## Architectural decisions

- Decision: **PDF gerado server-side via subprocess Python `reportlab`**.
  Rationale: backend é Lua baremetal sem Node; Python já está no stack de
  deploy (`scripts/data/*.py`); o audit trail fica server-side (requisito de
  compliance). Alternatives rejected: jspdf no frontend (audit trail
  client-side, quebra o requisito de evidência), lib Lua de PDF (imatura).
- Decision: **single-tenant workspace (v1)**. Rationale: app atual não tem
  auth (só API key); multi-tenant adicionaria escopo de auth/isolamento.
  Alternatives rejected: multi-tenant agora (escopo grande, sem base).
- Decision: **fonte MapBiomas = download em massa (shapefile/CSV)**.
  Rationale: espelha exatamente o padrão `download_sinaflor_auth.py` (CKAN →
  DB dedicado → scp → prod); sem token de API como moving part. Alternatives
  rejected: GraphQL V2 (requer conta/token, mais moving parts).
- Decision: **entrega de alerta = webhook + in-app (v1)**. Rationale: não há
  infra SMTP; webhook é a integração B2B padrão. Alternatives rejected:
  email SMTP (config nova, lib `socket/smtp.lua` presente mas não usada).
- Decision: **score de risco = tabela de regras com pesos por ICP** (não ML).
  Rationale: MVP defensável, auditável, calibrado por persona; ML é futuro.
  Source: modelo de severidade existente @ `deter_car_alerts.severity`.
- Decision: **armazenamento em DB dedicado** `backend-lua/data/mapbiomas/
  mapbiomas_alerta.db` (nunca toca `yvy.db`). Source: padrão `car.db` @
  `app/car_import.lua`, `app/lookups/car_lookup.lua:23-28`.
- Decision: **precompute + `version_key`** para scores por-propriedade.
  Source: `app/lookups/car_prodes.lua:120-140`.
- Decision: **parsing de body CSV raw** adicionado ao `server.lua` (POST já
  existe). `MAX_REQUEST_SIZE` do `server.lua` elevado (env). Em produção, o
  gate real é o **nginx `client_max_body_size`** (default 1MB, não
  configurado) — precisa ser setado em `ansible/templates/yvy-nginx.conf.j2`.
  Em dev/local, o proxy C `yvy-server.c`'s `MAX_REQUEST_SIZE` também precisa
  ser elevado + rebuild. Source: `yvy-server.c:76`, `server.lua:42,126`,
  `ansible/templates/yvy-nginx.conf.j2:65-66`, `main.lua:163-165,354-356`.

## Assumptions and answers from code

- Decision: rotas registradas em `main.lua` via `server.route(method, path,
  handler)`; handlers em `app/routes/*.lua` com `auth.enforce(ctx)` +
  `rl.enforce(ctx)`. Source: code @ `main.lua:142-400`, `app/server.lua`.
- Decision: `utils.parse_csv(text)` já existe e reutilizável para upload.
  Source: code @ `app/utils.lua:98`.
- Decision: `http_client.post` já faz POST JSON — reutilizável para webhook.
  Source: code @ `app/http_client.lua`.
- Decision: `redis.setnx` é o lock padrão de job dedup. Source: code @
  `app/redis.lua`, `fires.lua:520-580`.
- Decision: testes usam busted + `helpers.lua` (`days_ago`, `fake_ctx`),
  temp DBs, Redis stub com teardown. Source: code @ `tests/helpers.lua`,
  `tests/test_car_prodes.lua`.
- Decision: jobs agendados = systemd timers via Ansible. Source: code @
  `ansible/templates/yvy-deter-daily.timer.j2`.
- Decision: frontend usa `cachedFetch`/`useCardData`/`CardShell`, rotas lazy
  em `App.js`, i18n `t('risk.*')`. Source: code @ `frontend/src/utils/
  apiCache.js`, `frontend/src/components/Dashboard/useCardData.js`,
  `frontend/src/App.js`.

## Risks accepted

- **MapBiomas bulk download pode mudar de schema**: mitigado por descoberta
  em runtime (common-mistake #4) + normalização no import; falha loga alto.
- **Score v1 é heurístico, não calibrado**: aceito; pesos por ICP em tabela
  editável; calibração com decisões reais é fase 2.
- **Webhook sem retry persistente**: mitigado com retry simples + log; fila
  durável é fase 2.
- **PDF via subprocess Python adiciona dep runtime**: aceito; Python já no
  stack; `reportlab` adicionado a `scripts/requirements.txt`.
- **POST route é mudança no core server**: mitigado por testes de rota;
  body parsing isolado em helper; rotas existentes intocadas.

## Increment DAG

- Inc 1 — MapBiomas Alerta ingestion (M) — depends: none — unblocks: 2, 6
- Inc 2 — Risk score engine + precompute (M) — depends: 1 — unblocks: 3, 4, 6
- Inc 3 — Batch analysis API (L) — depends: 2 — unblocks: 5
- Inc 4 — PDF report generator (M) — depends: 2 — unblocks: 5
- Inc 5 — Frontend Risk Intelligence page (L) — depends: 3, 4, 6
- Inc 6 — Continuous monitoring + webhook alerts (L) — depends: 1, 2 — unblocks: 5 (alerts tab)

## Increments

### Inc 1 — MapBiomas Alerta ingestion (M) — DONE

**Depends on:** none
**Unblocks:** 2, 6
**Done criteria:** `mapbiomas_alerta.db` populado com alertas de desmatamento
(polígonos + atributos) e lookup runtime retorna alertas por bbox/CAR.

#### Files to touch

##### scripts/data/download_mapbiomas_alerta.py (new)
- What changes: baixa alertas MapBiomas Alerta (shapefile/CSV) e grava DB
  dedicado.
- Function(s): `main()`, `download_alerts(out_dir)`, `normalize_row(row)`,
  `build_db(rows, out_db)`, `resolve_car(row)`.
- Data shapes: input = shapefile/CSV da plataforma (colunas `alert_code`,
  `source`, `area_ha`, `biome`, `state`, `city`, `ano_det`, geometria);
  output = tabela `alerts(id, alert_code UNIQUE, source, area_ha, biome,
  state, city, ano_det, data_deteccao, data_publicacao, geom BLOB, bbox)` +
  `alerts_rtree(id, minLon, maxLon, minLat, maxLat)`.
- Integration points: espelha `download_sinaflor_auth.py` (CKAN → DB
  dedicado, `<out>.tmp` + `os.replace` atômico). `--today` para testes,
  `--force`, `--window`.
- Error paths: download falha → retry/backoff; schema muda → descoberta em
  runtime + log alto; DB swap atômico preserva DB anterior em falha.

##### backend-lua/app/lookups/mapbiomas_lookup.lua (new)
- What changes: lookup runtime em memória/índice dos alertas.
- Function(s): `_M.is_loaded()`, `_M.get_alerts_in_bbox(sw_lat, ne_lat,
  sw_lng, ne_lng, limit)`, `_M.get_alerts_by_car(cod_imovel)`,
  `_M.get_recent_alerts(days)`.
- Data shapes: retorna `{alert_code, source, area_ha, biome, state, city,
  ano_det, data_deteccao, lat, lon}`.
- Integration points: abre DB com `PRAGMA query_only=ON` (sobrevive swap);
  `is_loaded()` memo 60s (padrão `sinaflor_lookup.lua`).
- Error paths: DB ausente → `{found=false, reason="mapbiomas_unavailable"}`.

##### backend-lua/Makefile (edit)
- What changes: alvo `ingest-mapbiomas` → `python3 scripts/data/
  download_mapbiomas_alerta.py`.
- Integration points: espelha `ingest-sinaflor` no Makefile raiz.

##### scripts/deploy/sync-mapbiomas.sh (new)
- What changes: scp do DB dedicado para prod + verificação.
- Integration points: espelha `sync-sinaflor.sh`.

#### Edge cases
- Alertas que cruzam múltiplos biomas/estados: shapefile atribui predominante
  (maior área) — aceito, documentado.
- Geometria ausente/inválida: linha descartada com log.
- `ano_det` ausente: `nil` → tratado como desconhecido.

#### Verification
- Run: `python3 scripts/data/download_mapbiomas_alerta.py --today --force`
- Tests to add/update: `tests/test_mapbiomas_lookup.lua` (bbox query, CAR
  query, DB ausente → graceful degradation).
- Done: DB populado; lookup retorna alertas; teste passa.

### Inc 2 — Risk score engine + precompute (M) — DONE

**Depends on:** 1
**Unblocks:** 3, 4, 6
**Done criteria:** `score_property(cod_imovel)` retorna score 0–100 +
recomendação; precompute grava `risk_scores` com `version_key` invalidação.

#### Files to touch

##### backend-lua/app/risk_score.lua (new)
- What changes: motor de score puro (sem I/O), tabela de regras com pesos por
  ICP.
- Function(s): `_M.score(property, ctx)` → `{score, level, recommendation,
  factors}`; `_M.resolve_property_id(row)` → `string`; `_M.LEVELS = {alto,
  medio, baixo}`; `_M.WEIGHTS` (tabela por ICP).
- Data shapes: input `property = {cod_imovel, area_ha, uf, municipio}` + `ctx
  = {deforestation, protected_overlap, embargo, car_status, fires}`; output
  `{score 0-100, level, recommendation, factors[{name, weight, value}]}`.
  `resolve_property_id({cod_imovel?, cnpj?, lat?, lon?})` → `cod_imovel` se
  presente, senão `cnpj`, senão `lat:lon` (centroide). Função pura — chamada
  por `run_batch_analysis.lua` e `scan_supplier_alerts.lua` para garantir
  chave consistente.
- Integration points: puro — testável sem DB; consumido por precompute,
  batch API, PDF, monitor.
- Error paths: dados ausentes → fator neutro (peso 0), nunca crash.

##### backend-lua/app/lookups/risk_precompute.lua (new)
- What changes: lookup + writer offline (padrão `car_prodes`).
- Function(s): `_M.get(property_id)`, `_M.upsert(row)`, `_M.bulk_upsert(rows)`,
  `_M.version_key(source_hash, params)`.
- Data shapes: tabela `risk_scores(property_id TEXT PRIMARY KEY, score, level,
  recommendation, factors BLOB, version_key, computed_at)` em **DB dedicado
  `backend-lua/data/risk/risk.db`** (nunca toca `yvy.db`). `property_id` é um
  **surrogate** que reconcilia as três chaves de entrada: `cod_imovel` quando
  existe, senão `cnpj`, senão `lat:lon` (centroide).
- Integration points: `version_key` invalida quando MapBiomas/PRODES/UC/TI
  muda (padrão `car_prodes.lua:120-140`).
- Error paths: row stale (version_key mismatch) → recompute.

##### backend-lua/tools/warm_risk_scores.lua (new)
- What changes: subprocess destacado que precompute scores em lote.
- Function(s): `_M.main()`, guard `is_main` (require-able p/ testes).
- Integration points: `nohup lua5.1 tools/warm_risk_scores.lua` + lock
  `redis.setnx("risk:precompute:lock")`; escreve `risk:precompute:last_run`.
- Error paths: lock ocupado → skip; falha parcial → retry idempotente.

##### backend-lua/Makefile (edit)
- What changes: alvo `warm-risk-scores` → `lua5.1 tools/warm_risk_scores.lua`.

#### Edge cases
- Score 0 (sem dados) vs score baixo: distinguir "sem evidência" de "risco
  baixo" (fator `evidence_gap`).
- ICP desconhecido: fallback para pesos default.

#### Verification
- Run: `lua5.1 tools/warm_risk_scores.lua`
- Tests to add/update: `tests/test_risk_score.lua` (fatores, níveis,
  recomendação, dados ausentes → neutro, `resolve_property_id` para as 3
  chaves de entrada).
- Done: score determinístico; precompute grava com version_key; teste passa.

### Inc 3 — Batch analysis API (L) — DONE

**Depends on:** 2
**Unblocks:** 5
**Done criteria:** `POST /api/risk/batch` aceita CSV raw, dispara job
assíncrono, `GET /api/risk/batch?id=<batch_id>` retorna progresso +
resultados por propriedade.

#### Files to touch

##### backend-lua/app/server.lua (edit)
- What changes: `MAX_REQUEST_SIZE` default elevado (1MB → 8MB) para uploads
  de CSV raw; sem novo parsing (body CSV raw vai direto ao `parse_csv`).
- Function(s): `MAX_REQUEST_SIZE` @ `server.lua:42` (env-configurable).
- Integration points: `parse_request` já lê body via `Content-Length` @
  `server.lua:121-132`; `ctx.req.body` já é string raw — passa direto ao
  `utils.parse_csv`.
- Error paths: body > MAX → 413 (já tratado @ `server.lua:126-127`).

##### ansible/templates/yvy-nginx.conf.j2 (edit) — **o gate real de upload em prod**
- What changes: setar `client_max_body_size` (ex: `8m`) no `location /api/`
  (ou globalmente). Sem isso, nginx rejeita body >1MB com 413 antes do Lua.
- Integration points: `location /api/ { proxy_pass http://127.0.0.1:5000; }`
  @ `yvy-nginx.conf.j2:65-66` — rota direto ao Lua, bypassa C server.
- Error paths: body > `client_max_body_size` → 413 do nginx.
- **Nota DoS**: `8m` global permite bodies grandes em todas as rotas. Mitigar
  com `client_max_body_size 8m` apenas no `location /api/risk/` (ou
  `location /api/`), mantendo 1m default para o resto.

##### backend-lua/yvy-server.c (edit) — **gate dev/local (sem nginx)**
- What changes: elevar `MAX_REQUEST_SIZE` (1MB → 8MB) para paridade dev/local;
  rebuildar `yvy-server` (via `backend-lua/Makefile`). Em prod este binário só
  serve arquivos estáticos (nginx bypassa para `/api/*`).
- Function(s): `#define MAX_REQUEST_SIZE` @ `yvy-server.c:76`.
- Integration points: só é gate quando não há nginx (dev/local).
- Error paths: body > MAX → 413 (já tratado no C).

##### backend-lua/app/routes/risk.lua (new)
- What changes: handlers de batch analysis.
- Function(s): `_M.post_batch(ctx)`, `_M.get_batch(ctx)`,
  `_M.get_batch_result(ctx)`.
- Data shapes: POST body = **CSV raw** (`Content-Type: text/csv`, colunas
  `cnpj`, `cod_imovel`, `lat`, `lon`, `nome`); `ctx.req.body` é string raw →
  `utils.parse_csv(ctx.req.body)` direto (sem multipart). Response
  `{batch_id, status, total, processed, results[]}`.
- Integration points: `auth.enforce` + `rl.enforce`; `utils.parse_csv`
  (body raw CSV, sem multipart); dispara `tools/run_batch_analysis.lua` via
  `nohup` + lock `redis.setnx("risk:batch:<id>")`; progresso em Redis
  `risk:batch:<id>`.
- Error paths: CSV inválido → 400 com linha/coluna; job falha → status
  `failed` + erro.

##### backend-lua/tools/run_batch_analysis.lua (new)
- What changes: subprocess que processa o lote (score por propriedade).
- Function(s): `_M.main(batch_id)`, `_M.process_row(row)`.
- Integration points: lê CSV do Redis/arquivo, chama `risk_score.score` +
  `risk_precompute.upsert`, grava progresso em Redis.
- Error paths: propriedade sem match → `{found=false, reason}` (não aborta
  lote).
- **Detach**: fechar/redirecionar o fd do socket herdado do cliente (gotcha do
  proxy C) para o POST `/api/risk/batch` retornar o `batch_id` cedo, sem
  esperar o filho terminar.

##### backend-lua/main.lua (edit)
- What changes: registra `POST /api/risk/batch`, `GET /api/risk/batch`,
  `GET /api/risk/batch/:id` (via query arg `id` — router é exact-path).

#### Edge cases
- Lote grande (1.800 propriedades): processamento assíncrono, progresso
  incremental, sem bloquear o loop.
- Duplicatas no CSV: dedup por `cod_imovel`/`cnpj`.

#### Verification
- Run: `curl -X POST -H 'Content-Type: text/csv' --data-binary @suppliers.csv /api/risk/batch`
- Tests to add/update: `tests/test_risk_routes.lua` (POST validação, GET
  progresso, CSV inválido → 400).
- Done: upload → job → resultados; teste passa.

### Inc 4 — PDF report generator (M) — DONE

**Depends on:** 2
**Unblocks:** 5
**Done criteria:** `GET /api/risk/report?id=<property_id>` retorna PDF
profissional (score, fatores, recomendação, branding) para download.

#### Files to touch

##### scripts/data/render_risk_report.py (new)
- What changes: gera PDF via `reportlab` a partir do score.
- Function(s): `main(batch_id, property_id)`, `render_report(score, out)`.
- Data shapes: input = score JSON (de `risk_precompute.get`); output = PDF
  bytes.
- Integration points: subprocess Python invocado pelo handler Lua via
  `io.popen`/`os.execute`; `reportlab` adicionado a `scripts/requirements.txt`.
- Error paths: reportlab ausente → 500 com mensagem clara; score ausente →
  404.
- **Detach**: fechar/redirecionar o fd do socket herdado do cliente (gotcha do
  proxy C) para a rota de PDF não pendurar até o filho terminar.
- **Tamanho**: PDF multi-página com gráficos pode exceder `MAX_RESPONSE_SIZE`
  (2MB) do proxy C. Mitigar com (a) cap/stream do PDF para ficar abaixo do
  buffer, ou (b) elevar `MAX_RESPONSE_SIZE` em `yvy-server.c` junto com a
  mudança de request size.

##### backend-lua/app/routes/risk.lua (edit)
- What changes: handler `_M.get_report(ctx)`.
- Function(s): `_M.get_report(ctx)`.
- Integration points: lê score, spawna `render_risk_report.py`, serve via
  `ctx:send(200, pdf_bytes, "application/pdf")` (MIME já mapeado em
  `server.lua:200`).
- Error paths: PDF falha → 500; score ausente → 404.

##### backend-lua/main.lua (edit)
- What changes: registra `GET /api/risk/report`.

#### Edge cases
- Laudo com branding do cliente (v1: branding Yvy; white-label fase 2).
- Assinatura digital: fase 2 (v1: metadados + timestamp).

#### Verification
- Run: `curl -o report.pdf /api/risk/report?id=...`
- Tests to add/update: `tests/test_risk_report.lua` (PDF bytes válidos,
  score ausente → 404).
- Done: PDF gerado e servido; teste passa.

### Inc 5 — Frontend Risk Intelligence page (L) — DONE

**Depends on:** 3, 4, 6
**Unblocks:** none
**Done criteria:** página `/risk-intelligence` com upload CSV, tabela de
resultados com score, download de PDF, e aba de alertas de monitoramento
(consumindo Inc 6).

#### Files to touch

##### frontend/src/App.js (edit)
- What changes: rota lazy `/risk-intelligence` → `RiskIntelligence`.
- Integration points: padrão lazy + `<Route>` existente.

##### frontend/src/components/Navbar.js (edit)
- What changes: link de nav + i18n key `nav.risk`.

##### frontend/src/components/RiskIntelligence/RiskIntelligence.js (new)
- What changes: página principal.
- Function(s): `RiskIntelligence()`, `UploadForm`, `ResultsTable`,
  `ScoreBadge`, `AlertsTab`.
- Integration points: `cachedFetch`/`useCardData`/`CardShell`; upload via
  `fetch('/api/risk/batch', {method:'POST', headers:{'Content-Type':'text/csv'},
  body: csvText})` (CSV raw, sem `FormData`); polling de progresso; download
  PDF via `window.open('/api/risk/report?id=...')`; `AlertsTab` consome
  `GET /api/risk/supplier-alerts` (Inc 6).
- Error paths: upload falha → erro no CardShell; job falha → estado `error`.

##### frontend/src/components/RiskIntelligence/RiskIntelligence.css (new)
- What changes: estilos com design tokens (`--surface-*`, `--signal`,
  `--ember-*`); sem glass/drop-shadow sobre mapa (regra repo memory).

##### frontend/src/i18n.js (edit)
- What changes: seção `risk:` em `pt` e `en`.

#### Edge cases
- Score 0 vs baixo: badge distingue "sem evidência" de "risco baixo".
- Lote grande: tabela paginada/virtualizada.

#### Verification
- Run: `cd frontend && npm run build`
- Tests to add/update: build passa; (sem test runner frontend — validação
  manual + build).
- Done: página navegável, upload → resultados → PDF.

### Inc 6 — Continuous monitoring + webhook alerts (L) — DONE

**Depends on:** 1, 2
**Unblocks:** 5 (alerts tab)
**Done criteria:** job agendado detecta novo desmatamento em fornecedores
monitorados e dispara webhook + expõe alerta in-app.

#### Files to touch

##### backend-lua/app/lookups/supplier_monitor.lua (new)
- What changes: lookup + writer de fornecedores monitorados.
- Function(s): `_M.get_suppliers()`, `_M.upsert_supplier(row)`,
  `_M.get_supplier(cnpj)`.
- Data shapes: tabela `suppliers(cnpj PRIMARY KEY, nome, cod_imovel, lat,
  lon, webhook_url, status, last_score, last_alert_at)`.
- Integration points: DB dedicado `suppliers.db` (padrão `car.db`).

##### backend-lua/tools/scan_supplier_alerts.lua (new)
- What changes: subprocess destacado que cruza alertas MapBiomas recentes com
  fornecedores monitorados.
- Function(s): `_M.main()`, `_M.check_supplier(supplier, recent_alerts)`.
- Integration points: `mapbiomas_lookup.get_recent_alerts(days)` ×
  `supplier_monitor.get_suppliers()`; lock `redis.setnx("risk:monitor:lock")`;
  escreve `risk:supplier_alert:<cnpj>` (TTL) + `risk:monitor:last_run`.
- Error paths: webhook falha → retry simples + log; sem alerta → skip.

##### backend-lua/app/routes/risk.lua (edit)
- What changes: handlers de monitoramento.
- Function(s): `_M.post_supplier(ctx)`, `_M.get_suppliers(ctx)`,
  `_M.get_supplier_alerts(ctx)`.
- Integration points: CRUD de fornecedores + listagem de alertas in-app.

##### scripts/data/scan_supplier_alerts.sh (new)
- What changes: wrapper bash que roda o scan (padrão `deter_daily.sh`).

##### ansible/templates/yvy-risk-monitor.service.j2 (new)
- What changes: unit systemd oneshot.
- Integration points: espelha `yvy-deter-daily.service.j2`.

##### ansible/templates/yvy-risk-monitor.timer.j2 (new)
- What changes: timer diário (ex: `OnCalendar=*-*-* 05:30:00`,
  `RandomizedDelaySec=300`).
- Integration points: espelha `yvy-deter-daily.timer.j2`.

##### ansible/playbook.yml (edit)
- What changes: 3 tasks (template service, template timer, enable timer).

##### backend-lua/main.lua (edit)
- What changes: registra `POST /api/risk/supplier`, `GET /api/risk/suppliers`,
  `GET /api/risk/supplier-alerts`.

#### Edge cases
- Fornecedor sem `cod_imovel`/coordenadas: monitora por bbox/centroide.
- Novo desmatamento em fornecedor já em risco: alerta de escalada (status
  anterior → atual).

#### Verification
- Run: `bash scripts/data/scan_supplier_alerts.sh`
- Tests to add/update: `tests/test_supplier_monitor.lua` (CRUD, scan detecta
  alerta, webhook chamado, teardown Redis).
- Done: scan detecta alerta, webhook dispara, alerta in-app visível.

## Cross-cutting verification

- Após Inc 3: upload CSV >1MB passa pelo nginx (`client_max_body_size`
  configurado em `yvy-nginx.conf.j2`) e pelo `server.lua` (`MAX_REQUEST_SIZE`
  elevado); POST retorna `batch_id` cedo (sem pendurar no filho). Em dev/local,
  `yvy-server.c` rebuildado com cap elevado.
- Após Inc 4: PDF multi-página servido sem truncar (abaixo de
  `MAX_RESPONSE_SIZE` ou cap elevado).
- Após Inc 5: walkthrough manual em `/risk-intelligence` — upload CSV (raw,
  `Content-Type: text/csv`) → progresso → resultados → download PDF → aba de
  alertas.
- Após Inc 6: verificar alerta in-app + webhook recebido para um fornecedor
  com desmatamento recente.
- `make test-lua` verde após cada incremento (CI roda `busted --verbose
  tests/*.lua` + `luac -p` + `sh -n` + `py_compile` + `npm run build`).
- **Rollback**: cada incremento que muda o nginx, proxy C ou `server.lua` deve
  ser revertível sem perder os DBs dedicados novos (swap `os.replace` preserva
  o DB anterior; reverter o binário `yvy-server` antigo restaura o gate
  dev/local; reverter `yvy-nginx.conf.j2` restaura o gate de prod).

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` — applies to: todos os
  incrementos (fixtures clock-relative, teardown Redis, batching N+1,
  schema runtime, marker-after-success, pandas Series, react-leaflet popup).
- `.agents/AGENTS.md` — applies to: arquitetura Lua, JSONB, deploy, env vars.
- `.agents/DESIGN.md` — applies to: Inc 5 (design tokens, sem glass).

## Open questions (CONSIDER from review)

- **Inc 1 data-source**: o download em massa do MapBiomas Alerta NÃO é CKAN
  (diferente do Sinaflor) — distribui shapefiles/CSVs por estado via portal
  próprio + API "Meu MapBiomas". Verificar o mecanismo real de bulk download
  e o schema (multi-biome, `ano_det`) ANTES de Inc 1; o espelhamento do
  `download_sinaflor_auth.py` pode não se aplicar diretamente.
- **Inc 3/4 paralelismo**: Inc 3 e Inc 4 são independentes após Inc 2 (ambos
  → 5). Podem rodar em paralelo se o orquestrador quiser throughput.
- **Webhook retry**: Inc 6 não especifica retry/backoff, dead-letter ou log
  para webhook falho. Para alerta de compliance, uma entrega falha deve ser
  visível e retentada.
- **DoS do cap 8MB**: `client_max_body_size 8m` no nginx permite bodies
  grandes. Preferir escopo por-rota (`location /api/risk/`) em vez de global.
- **Supplier com múltiplas propriedades**: a tabela `suppliers` (Inc 6) é
  `cnpj PK`, mas um fornecedor pode ter múltiplos `cod_imovel`. Considerar
  `(cnpj, cod_imovel)` composite PK ou tabela `supplier_properties` separada.

## Out of scope

- Multi-tenant/auth de usuário (fase 2).
- ML para score (fase 2 — v1 é tabela de regras).
- Email SMTP (v1 é webhook + in-app).
- Assinatura digital de PDF (fase 2).
- Rastreabilidade EUDR completa (requer competência jurídica — gap que o Yvy
  não deve cobrir).
- Visualização de mapas customizada / chatbot RAG (compete com MapBiomas
  gratuito).
