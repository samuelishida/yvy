# Yvy CAR Risk Expansion — Área Efetiva, Embargo e Laudo Enriquecido

> STATUS: reviewed — self-review + review-plan aplicado (10 findings: 3 MUST-FIX, 4 SHOULD-FIX, 3 CONSIDER). Inc 1 done. Inc 2 done. Inc 3 done. Inc 4 done.

## Context

O `risk-intelligence` (score 0–100, batch CSV, PDF laudo, monitor de
fornecedores, página `/risk-intelligence`) está **implementado e verificado**
(busted 278/0). O MapBiomas é o floor, não o teto. A expansão transforma o
**CAR** no núcleo do produto de decisão, preenchendo os "buracos" que o
MapBiomas não resolve:

1. **Sobreposição** — um alerta de 12 ha cruza com 2+ CARs; hoje o score usa
   `recent_alerts` (área total do alerta), não a **área efetiva dentro de cada
   imóvel**. O frigorífico não sabe se 67% do risco é do fornecedor Y ou Z.
2. **Embargo oculto** — o fator `embargo` (peso 0.20) existe no
   `risk_score.lua` mas **nunca é alimentado** (`ctx.embargo` sempre nil). Não
   há dataset de embargo IBAMA.
3. **Laudo rico** — o PDF atual (`render_risk_report.py`) é 1 página: score,
   nível, recomendação, tabela de fatores. Não tem identificação cadastral,
   eventos, sobreposições, histórico, evidências.

**Restrições herdadas do código** (verificadas em exploração):
- Backend **Lua 5.1, loop copas single-threaded** — nenhum cruzamento espacial
  denso nem geração de PDF no loop. Trabalho pesado roda em **subprocesso
  destacado** (`tools/*.lua` + `nohup` + lock Redis `setnx`).
- **Não existe primitiva de interseção polígono-polígono em Lua.** O único
  cruzamento real está em Python (`scripts/data/cross_deter_car.py`, Shapely +
  CRS equal-area EPSG:5880). O padrão estabelecido é: **offline em Python com
  Shapely → DB dedicado → `version_key` → leitor `query_only=ON`** (espelha
  `car_prodes`, `car_protected_overlap`).
- Datasets externos usam **DB SQLite dedicado** com swap atômico `os.replace`
  + leitores `PRAGMA query_only=ON` — nunca tocam o `yvy.db` vivo.
- **O gate de upload em produção já está resolvido**: o nginx
  (`yvy-nginx.conf.j2`) configura `client_max_body_size 8m` no location
  `/api/risk/` — o batch CSV até 8MB passa. O `server.lua` `MAX_REQUEST_SIZE`
  (1MB default) é o segundo gate para outros POSTs.
- PDF é **server-side via subprocess Python `reportlab`** (decisão de
  compliance/audit trail do plano risk-intelligence).
- Rotas registradas em `main.lua` via `server.route(method, path, handler)`;
  handlers em `app/routes/*.lua` com `auth.enforce(ctx)` + `rl.enforce(ctx)`.
- Testes: busted + `helpers.lua` (`days_ago`, `fake_ctx`), temp DB por arquivo
  com `os.time()`, Redis stub com teardown, subprocess scripts require-able.

## Architectural decisions

- Decision: **área efetiva calculada offline em Python (Shapely + CRS
  equal-area), pré-computada em DB dedicado com `version_key`**. Rationale:
  o loop Lua é single-threaded e não tem primitiva de interseção; o padrão
  `cross_deter_car.py` + `car_prodes`/`car_protected_overlap` já é o template
  provado. Alternatives rejected: interseção em Lua (sem primitiva, custo no
  loop), interseção on-the-fly por request (lento, sem cache).
- Decision: **embargo IBAMA ingerido via CKAN `dadosabertos.ibama.gov.br`**
  (mesmo padrão `download_sinaflor_auth.py`), DB dedicado `embargo.db` com
  swap atômico. Rationale: sem credenciais, fonte aberta, padrão já provado.
  Alternatives rejected: API IBAMA com token (moving part), scraping (frágil).
- Decision: **laudo enriquecido = estender `render_risk_report.py` para
  multi-página** (identificação, eventos, sobreposições, histórico, evidências)
  consumindo um **JSON de contexto enriquecido** produzido pelo backend.
  Rationale: mantém o audit trail server-side; reportlab já no stack.
  Alternatives rejected: jspdf no frontend (quebra requisito de evidência).
- Decision: **novo fator `area_efetiva` no score** substituindo o uso de
  `recent_alerts` (área total) pela área efetiva dentro do imóvel. Rationale:
  é o diferencial central; o fator `deforestation` passa a usar a fração
  efetiva. O fator `embargo` passa a ser alimentado de verdade.
- Decision: **`risk_score.lua` permanece PURA (sem DB/Redis)** — os lookups
  (`area_efetiva_lookup`, `embargo_lookup`) são invocados nos **chamadores**
  (`run_batch_analysis.lua`, `warm_risk_scores.lua`, `scan_supplier_alerts.lua`),
  que populam `ctx.area_efetiva_ha` / `ctx.embargo`. Rationale: preserva o
  contrato de pureza (testável isoladamente) e o padrão existente. Source:
  header de `risk_score.lua` ("puro, sem I/O").
- Decision: **single-tenant, branding Yvy** (white-label adiado). Source:
  decisão do plano risk-intelligence; confirmado pelo usuário.
- Decision: **fontes de dados assumidas como open-data, com verificação de
  schema em runtime** (common-mistake #4). Rationale: usuário não confirmou
  credenciais; o padrão de descoberta em runtime evita quebra silenciosa.

## Assumptions and answers from code

- Decision: `risk_score.lua` já tem fatores `embargo` (0.20) e `car_status`
  (0.10) com pesos, mas `ctx.embargo` nunca é alimentado. Source: code @
  `backend-lua/app/risk_score.lua:20-30, 80-100`.
- Decision: `risk_precompute.lua` já tem `version_key` + `bulk_upsert` +
  leitor `query_only=ON` — reutilizável para o novo DB de área efetiva.
  Source: code @ `backend-lua/app/lookups/risk_precompute.lua`.
- Decision: **`current_version_key()` precisa incluir a versão da área
  efetiva** (ex. `AREA_EFETIVA_VERSION` env) para que um recomputo da área
  efetiva invalide os scores cacheados que a consomem. Source: code @
  `backend-lua/app/lookups/risk_precompute.lua` (deriva de
  RISK/PRODES/MAPBIOMAS_VERSION).
- Decision: `car_lookup.lua` expõe `get_by_cod_imovel(cod_imovel)` → `{id, uf,
  municipio, area_ha, geom, bbox}` — base para resolver o imóvel no laudo.
  Source: code @ `backend-lua/app/lookups/car_lookup.lua`.
- Decision: `mapbiomas_lookup.lua` expõe `get_alerts_by_car(cod_imovel)` e
  `get_recent_alerts(days)` — base para eventos no laudo. Source: code @
  `backend-lua/app/lookups/mapbiomas_lookup.lua`.
- Decision: `car_protected_overlap.lua` + `conservation_units_lookup.lua` +
  `indigenous_lands_lookup.lua` já fornecem sobreposição UC/TI (Monte-Carlo).
  Source: code @ `backend-lua/app/lookups/car_protected_overlap.lua`.
- Decision: `sinaflor_lookup.lua` já fornece autorização de supressão
  (ASV/AUTESP) — reutilizável na seção "autorização" do laudo. Source: code @
  `backend-lua/app/lookups/sinaflor_lookup.lua`.
- Decision: `utils.parse_csv(text)` já existe e é reutilizável. Source: code @
  `backend-lua/app/utils.lua:98`.
- Decision: `http_client.post` já faz POST JSON — reutilizável para webhook.
  Source: code @ `backend-lua/app/http_client.lua`.
- Decision: `redis.setnx` é o lock padrão de job dedup. Source: code @
  `backend-lua/app/redis.lua`.
- Decision: jobs agendados = systemd timers via Ansible. Source: code @
  `ansible/templates/yvy-deter-daily.timer.j2`.
- Decision: frontend usa `cachedFetch`/`useCardData`/`CardShell`, rotas lazy
  em `App.js`, i18n `t('risk.*')`. Source: code @ `frontend/src/utils/
  apiCache.js`, `frontend/src/App.js`.
- Decision: nginx **já configura `client_max_body_size 8m`** no location
  `/api/risk/` — o gate de upload já está resolvido para o batch CSV. Source:
  code @ `ansible/templates/yvy-nginx.conf.j2:99`.

## Risks accepted

- **Fontes SIGEF/SNCI/embargo/CAR-status não verificadas**: assumidas como
  open-data; mitigado por descoberta em runtime (common-mistake #4) + log
  alto em falha. Se a fonte não existir, o incremento correspondente é
  re-escopado. (SIGEF/SNCI e CAR-status estão fora do escopo Core-3; embargo
  é o único dataset novo neste plano.)
- **Área efetiva pré-computada pode ficar stale**: mitigado por `version_key`
  (invalida quando PRODES/MAPBIOMAS/CAR version muda) + job diário.
- **Laudo multi-página pode crescer**: `/api/risk/report` proxy direto ao Lua
  `:5000` (bypassa o cap 2MB do proxy C); ainda assim, manter imagens/gráficos
  leves e servir via download (Content-Disposition) se o PDF ficar grande.
- **Score v1 heurístico**: aceito; pesos por ICP em tabela editável;
  calibração com decisões reais é fase 2.

## Increment DAG

- Inc 1 — Área efetiva (offline precompute) (L) — depends: none — unblocks: 3
- Inc 2 — Embargo IBAMA ingest + lookup + wiring (M) — depends: none — unblocks: 3
- Inc 3 — Score enriquecido + laudo multi-página (L) — depends: 1, 2 — unblocks: 4
- Inc 4 — Frontend laudo viewer + área efetiva (M) — depends: 3 — unblocks: none

## Increments

### Inc 1 — Área efetiva por imóvel (offline precompute) (L)

**Depends on:** none
**Unblocks:** 3
**Done criteria:** `area_efetiva.db` populado com a fração de cada alerta
dentro de cada CAR; lookup runtime retorna `{alert_code, cod_imovel,
area_efetiva_ha, fracao}`; teste passa.

#### Files to touch

##### scripts/data/compute_area_efetiva.py (new)
- What changes: cruza alertas MapBiomas × polígonos CAR, calcula área de
  interseção por par, grava DB dedicado.
- Function(s): `main()`, `load_alerts(db)`, `load_car(db)`, `intersect_pair(
  alert_geom, car_geom)`, `build_db(rows, out_db)`,
  `write_version_marker(version_str)`.
- Data shapes: input = `mapbiomas_alerta.db` (alerts + geom) e `car.db`
  (car_data + geom); output = tabela `area_efetiva(alert_code, cod_imovel,
  area_efetiva_ha REAL, fracao REAL, version_key TEXT)` + índice
  `(alert_code)`, `(cod_imovel)`.
- Integration points: espelha `cross_deter_car.py` (Shapely `intersection()`
  + CRS equal-area EPSG:5880, fallback UTM 23S). `--today` para testes,
  `--force`, `--window`. Swap atômico `<out>.tmp` + `os.replace`.
  **Ao concluir com sucesso**, grava `data/area_efetiva.version` com a
  string de versão (ex. `YYYYMMDD`), espelhando o padrão
  `data/prodes_version`. O Ansible service exporta
  `AREA_EFETIVA_VERSION` via `Environment=`.
- Error paths: geometria inválida → linha descartada com log; DB swap falha →
  preserva DB anterior; schema muda → descoberta em runtime + log alto.

##### backend-lua/app/lookups/area_efetiva_lookup.lua (new)
- What changes: lookup runtime em memória/índice da área efetiva.
- Function(s): `_M.is_loaded()`, `_M.get_by_alert(alert_code)`,
  `_M.get_by_car(cod_imovel)`, `_M.get_fracao(alert_code, cod_imovel)`.
- Data shapes: retorna `{alert_code, cod_imovel, area_efetiva_ha, fracao}`.
- Integration points: abre DB com `PRAGMA query_only=ON` (sobrevive swap);
  `is_loaded()` memo 60s (padrão `sinaflor_lookup.lua`).
- Error paths: DB ausente → `{found=false, reason="area_efetiva_unavailable"}`.

##### backend-lua/Makefile (edit)
- What changes: alvo `ingest-area-efetiva` → `python3 scripts/data/
  compute_area_efetiva.py`.
- Integration points: espelha `ingest-mapbiomas` no Makefile raiz.

##### scripts/deploy/sync-area-efetiva.sh (new)
- What changes: scp do DB dedicado para prod + verificação.
- Integration points: espelha `sync-sinaflor.sh`.

##### ansible/templates/yvy-area-efetiva.service.j2 + .timer.j2 (new)
- What changes: job diário de recomputo da área efetiva. O `.service.j2`
  define `Environment=AREA_EFETIVA_VERSION_FILE=/opt/yvy/data/area_efetiva.version`
  e o wrapper script lê o marker após a execução bem-sucedida.
- Integration points: espelha `yvy-risk-monitor.service.j2`/`.timer.j2`
  (oneshot, `Persistent=true`, `RandomizedDelaySec=300`, staggered).

#### Edge cases
- Alerta que cruza 2+ CARs: uma linha por par (alert_code, cod_imovel).
- Alerta em área não cadastrada: `fracao` < 1; a fração restante é
  "não cadastrada" (calculada no laudo como `1 - sum(fracao)`).
- Geometria ausente/inválida em qualquer lado: par descartado com log.
- `version_key` muda (PRODES/MAPBIOMAS/CAR version): recomputo invalida.

#### Verification
- Run: `python3 scripts/data/compute_area_efetiva.py --today --force`
- Tests to add/update: `tests/test_area_efetiva_lookup.lua` (query por alert,
  por car, DB ausente → graceful degradation).
- Done: DB populado; lookup retorna frações; teste passa.

### Inc 2 — Embargo IBAMA ingest + lookup + wiring (M)

**Depends on:** none
**Unblocks:** 3
**Done criteria:** `embargo.db` populado com embargos IBAMA; lookup runtime
retorna embargos por CAR/coordenada; os **chamadores** (`run_batch_analysis.lua`,
`warm_risk_scores.lua`, `scan_supplier_alerts.lua`) populam `ctx.embargo` via
`embargo_lookup` — o fator `embargo` do score passa a ser alimentado de verdade.

#### Pre-flight: embargo CKAN geometry verification

Antes de commitar o schema com `geom BLOB` + `embargoes_rtree`, executar:
1. Fetch CKAN metadata do dataset de embargos IBAMA
   (`dadosabertos.ibama.gov.br/api/3/action/package_show?id=...`).
2. Verificar se há resource com coluna de geometria (shapefile/GeoJSON
   com `geom` ou similar).
3. **Se geometria existe** → prosseguir com schema completo (`geom BLOB` +
   rtree + `get_at(lon, lat)`).
4. **Se geometria NÃO existe** (tabular-only: município/UF, sem polígono) →
   ajustar schema: remover `geom BLOB` e `embargoes_rtree`; `embargo_lookup`
   perde `get_at(lon, lat)`; matching fica só por `cod_imovel` (requer
   coluna `cod_imovel` no dataset, ou resolver via município/UF → CAR).
   Registrar o resultado da verificação no `shape.md`.

#### Files to touch

##### scripts/data/download_embargo.py (new)
- What changes: baixa embargos IBAMA do CKAN `dadosabertos.ibama.gov.br` e
  grava DB dedicado.
- Function(s): `main()`, `download_embargoes(out_dir)`, `normalize_row(row)`,
  `build_db(rows, out_db)`, `resolve_car(row)`.
- Data shapes: input = CKAN (colunas `numero_embargo`, `data_embargo`,
  `situacao`, `municipio`, `uf`, geometria); output = tabela `embargoes(
  id INTEGER PK, numero TEXT UNIQUE, data TEXT, situacao TEXT, municipio TEXT,
  uf TEXT, cod_imovel TEXT, geom BLOB, bbox TEXT)` + `embargoes_rtree(id,
  minLon, maxLon, minLat, maxLat)`.
- Integration points: espelha `download_sinaflor_auth.py` (CKAN → DB dedicado,
  `<out>.tmp` + `os.replace` atômico). `--today` para testes, `--force`,
  `--window`.
- Error paths: download falha → retry/backoff; schema muda → descoberta em
  runtime + log alto; DB swap atômico preserva DB anterior em falha.

##### backend-lua/app/lookups/embargo_lookup.lua (new)
- What changes: lookup runtime em memória/índice dos embargos.
- Function(s): `_M.is_loaded()`, `_M.get_by_car(cod_imovel)`,
  `_M.get_at(lon, lat)`, `_M.has_active_embargo(cod_imovel)`.
- Data shapes: retorna `{numero, data, situacao, municipio, uf}`.
- Integration points: abre DB com `PRAGMA query_only=ON`; `is_loaded()` memo
  60s (padrão `sinaflor_lookup.lua`).
- Error paths: DB ausente → `{found=false, reason="embargo_unavailable"}`.

##### backend-lua/app/risk_score.lua (edit)
- What changes: **sem mudança de assinatura** — o fator `embargo` já lê
  `ctx.embargo` (0..1). Nenhum lookup dentro do módulo (permanece puro).
- Function(s): inalteradas.
- Integration points: os chamadores injetam `ctx.embargo` real.
- Error paths: embargo DB ausente → `ctx.embargo = nil` (fator neutro, nunca
  crash).

##### backend-lua/tools/run_batch_analysis.lua (edit)
- What changes: ao montar o ctx de cada propriedade, consulta
  `embargo_lookup.has_active_embargo(cod_imovel)` e injeta `ctx.embargo`.
- Function(s): `_M.process_row(row)` — adiciona a consulta de embargo.
- Integration points: `embargo_lookup` (DB dedicado, `query_only=ON`).
- Error paths: embargo DB ausente → `ctx.embargo = nil` (fator neutro).

##### backend-lua/tools/warm_risk_scores.lua (edit)
- What changes: ao recomputar scores, injeta `ctx.embargo` via
  `embargo_lookup.has_active_embargo(cod_imovel)`. **Importante**:
  `build_ctx` atual retorna **all-nil** (não consulta `mapbiomas`). Para que
  o embargo tenha efeito, `build_ctx` também precisa da chamada
  `mapbiomas_lookup.get_alerts_by_car(cod_imovel)` (como `run_batch_analysis`
  já faz), senão `recent_alerts` fica nil e o score sai 0 com
  `evidence_gap=1` — inútil. **Este edit adiciona ambas as consultas**.
- Function(s): `_M.build_ctx(property)` — adiciona `mapbiomas.get_alerts_by_car`
  + `embargo_lookup.has_active_embargo`; `_M.run_batch(all, limit)` —
  injeta `ctx.embargo`.
- Integration points: `embargo_lookup`, `mapbiomas_lookup`.
- Error paths: embargo DB ausente → `ctx.embargo = nil`; mapbiomas DB ausente
  → `ctx.recent_alerts = nil` (score 0, evidência gap 1 — esperado quando
  não há dados).

##### backend-lua/tools/scan_supplier_alerts.lua (edit)
- What changes: ao avaliar fornecedores, injeta `ctx.embargo` via
  `embargo_lookup.has_active_embargo(cod_imovel)`. **Atenção**:
  `scan_supplier_alerts` também é editado no Inc 3 (para injetar
  `ctx.area_efetiva_ha`). Este edit (Inc 2) adiciona só `ctx.embargo`;
  `ctx.area_efetiva_ha` fica `nil` (não setado). O edit do Inc 3 adiciona
  `ctx.area_efetiva_ha` ao mesmo `check_supplier` — as duas edições são
  compatíveis porque cada uma adiciona um campo distinto ao ctx.
- Function(s): `_M.check_supplier(supplier, recent_alerts)` — adiciona a
  consulta de embargo.
- Integration points: `embargo_lookup`.
- Error paths: embargo DB ausente → `ctx.embargo = nil`.

##### backend-lua/Makefile (edit)
- What changes: alvo `ingest-embargo` → `python3 scripts/data/
  download_embargo.py`.
- Integration points: espelha `ingest-sinaflor`.

##### scripts/deploy/sync-embargo.sh (new)
- What changes: scp do DB dedicado para prod + verificação.
- Integration points: espelha `sync-sinaflor.sh`.

##### ansible/templates/yvy-embargo.service.j2 + .timer.j2 (new)
- What changes: job semanal de download de embargos.
- Integration points: espelha `yvy-risk-monitor.service.j2`/`.timer.j2`.

#### Edge cases
- Embargo ativo vs. suspenso: `has_active_embargo` considera só `situacao`
  ativa; suspenso → fator menor.
- Embargo sem CAR resolvido: fallback espacial lat/lon→polígono (padrão
  `download_sinaflor_auth.py`). Se o pre-flight confirmar que o dataset é
  tabular-only (sem geometria), este fallback não existe — matching fica
  só por `cod_imovel` ou município/UF.
- Múltiplos embargos no mesmo imóvel: fator = 1 se qualquer um ativo.

#### Verification
- Run: `python3 scripts/data/download_embargo.py --today --force`
- Tests to add/update: `tests/test_embargo_lookup.lua` (query por car, por
  coordenada, DB ausente → graceful degradation); `tests/test_risk_score.lua`
  (fator embargo alimentado); `tests/test_supplier_monitor.lua` (ctx.embargo
  injetado).
- Done: DB populado; lookup retorna embargos; chamadores injetam `ctx.embargo`;
  score usa embargo real.

### Inc 3 — Score enriquecido + laudo multi-página (L)

**Depends on:** 1, 2
**Unblocks:** 4
**Done criteria:** o score usa área efetiva + embargo real; o laudo PDF tem
múltiplas páginas (identificação, eventos, sobreposições, histórico,
evidências); teste passa.

#### Files to touch

##### backend-lua/app/risk_score.lua (edit)
- What changes: o fator `deforestation` passa a usar `ctx.area_efetiva_ha`
  (opcional) quando presente, em vez da área total do alerta. **Permanece
  puro** — nenhum lookup dentro do módulo.
- Function(s): `_M.score(property, ctx)` — `ctx` ganha `area_efetiva_ha`
  (opcional); `deforestation_factor` usa `area_efetiva_ha` quando presente,
  senão cai para `recent_alerts` (área total).
- Data shapes: `ctx.area_efetiva_ha` = soma das áreas efetivas dos alertas
  dentro do imóvel.
- **Calibração da fórmula**: o `deforestation_factor` atual usa
  `log(1 + total_area) / log(1 + 50)` como normalização (50 ha = referência).
  Quando `area_efetiva_ha` está presente, a mesma fórmula log-scale se
  aplica: `log(1 + area_efetiva_ha) / log(1 + 50)`. Como `area_efetiva_ha`
  é sempre ≤ `total_area`, o fator fica menor (ou igual) — esperado, pois
  o risco real do imóvel é proporcional à área efetiva, não à área total
  do alerta. Confirmar em `test_risk_score.lua` que a substituição não
  gera regressão para imóveis com área efetiva = área total (fracao = 1).
- Integration points: os chamadores injetam `ctx.area_efetiva_ha` via
  `area_efetiva_lookup`.
- Error paths: `ctx.area_efetiva_ha` ausente → fallback para `recent_alerts`
  (área total), nunca crash e nunca regressão silenciosa para 0.

##### backend-lua/tools/run_batch_analysis.lua (edit)
- What changes: ao montar o ctx, injeta `ctx.area_efetiva_ha` via
  `area_efetiva_lookup.get_by_car(cod_imovel)` (soma das áreas efetivas).
  **`process_row` também adiciona `area_efetiva_ha` ao payload da linha
  de resultado gravada no Redis** (`risk:batch:<id>`), para que o
  frontend (Inc 4) possa exibir a coluna sem um segundo lookup. Hoje
  `process_row` retorna `{found, property_id, nome, score, level,
  recommendation}` — passa a retornar `{..., area_efetiva_ha}`.
- Function(s): `_M.process_row(row)` — adiciona a consulta de área efetiva
  e o campo `area_efetiva_ha` no resultado Redis.
- Integration points: `area_efetiva_lookup`; `risk:batch:<id>` no Redis
  (lido por `risk.lua` `get_batch`).
- Error paths: área efetiva DB ausente → `ctx.area_efetiva_ha = nil`,
  resultado `area_efetiva_ha = nil` (fallback para `recent_alerts`).

##### backend-lua/tools/warm_risk_scores.lua (edit)
- What changes: ao recomputar scores, injeta `ctx.area_efetiva_ha` via
  `area_efetiva_lookup.get_by_car(cod_imovel)`. **Nota**: o edit do Inc 2
  já adicionou `mapbiomas.get_alerts_by_car` ao `build_ctx` (que era
  all-nil). Este edit (Inc 3) adiciona `area_efetiva_lookup.get_by_car`
  ao mesmo `build_ctx` — compatível porque adiciona um campo distinto.
- Function(s): `_M.build_ctx(property)` — adiciona
  `area_efetiva_lookup.get_by_car`; `_M.run_batch(all, limit)` —
  injeta `ctx.area_efetiva_ha`.
- Integration points: `area_efetiva_lookup`.
- Error paths: área efetiva DB ausente → `ctx.area_efetiva_ha = nil`.

##### backend-lua/tools/scan_supplier_alerts.lua (edit)
- What changes: ao avaliar fornecedores, injeta `ctx.area_efetiva_ha` via
  `area_efetiva_lookup.get_by_car(cod_imovel)`. **Compatibilidade com
  Inc 2**: o Inc 2 já adicionou `ctx.embargo` ao mesmo `check_supplier`.
  Este edit adiciona `ctx.area_efetiva_ha` — campos distintos, sem
  conflito. Ambos edits coexistem no mesmo arquivo após o merge.
- Function(s): `_M.check_supplier(supplier, recent_alerts)` — adiciona a
  consulta de área efetiva.
- Integration points: `area_efetiva_lookup`.
- Error paths: área efetiva DB ausente → `ctx.area_efetiva_ha = nil`.

##### backend-lua/app/lookups/risk_precompute.lua (edit)
- What changes: `current_version_key()` passa a incluir a versão da área
  efetiva (`AREA_EFETIVA_VERSION` env) — um recomputo da área efetiva
  invalida os scores cacheados que a consomem.
- Function(s): `_M.current_version_key()` — adiciona `AREA_EFETIVA_VERSION`
  ao hash.
- Integration points: `compute_area_efetiva.py` grava o marker de versão;
  `warm_risk_scores.lua` recomputa scores stale.
- Error paths: env ausente → usa valor default (não quebra).

##### backend-lua/app/routes/risk.lua (edit)
- What changes: `GET /api/risk/report` passa a montar um **JSON de contexto
  enriquecido** (identificação, eventos, sobreposições, histórico, evidências,
  geometrias para mapa estático) e passá-lo ao renderer.
- Function(s): `_M.get_report(ctx)` — chama `build_report_context(
  property_id)` (nova função local) que monta o `context.json`:
  ```lua
  local function build_report_context(property_id)
    -- 1. resolve cod_imovel a partir de property_id
    -- 2. car_lookup.get_by_cod_imovel → property geom (GeoJSON) + área
    -- 3. mapbiomas_lookup.get_alerts_by_car → alerts[] (sem geom)
    -- 4. area_efetiva_lookup.get_by_car → area_efetiva[]
    -- 5. embargo_lookup.get_by_car → embargoes[]
    -- 6. car_protected_overlap → protected[] (UC/TI)
    -- 7. sinaflor_lookup → sinaflor[] (ASV/AUTESP)
    -- 8. risk_precompute.get → score, level, recommendation, factors
    -- 9. history[] — snapshots históricos se disponíveis
    return context  -- table serializada como JSON
  end
  ```
  Todos os lookups são em memória/índice (`query_only=ON`, memo 60s),
  **sem cruzamento espacial denso** — o loop copas não é bloqueado.
- Data shapes: `context.json` = `{property, score, factors, alerts[],
  area_efetiva[], embargoes[], protected[], sinaflor[], history[],
  geometries: {property_geom: GeoJSON, alert_geoms: GeoJSON[]}}`.
- **Geometrias para o mapa P5**: `mapbiomas_lookup.get_alerts_by_car`
  **não retorna `geom`** (só lat/lon). Para o mapa estático P5 do laudo,
  `build_report_context` precisa obter as geometrias dos alertas. Duas
  opções (implementar a opção A, fallback B):
  - **(A) Estender `mapbiomas_lookup.get_alerts_by_car`** para incluir `geom`
    (WKT blob do `mapbiomas_alerta.db`) no retorno quando um flag
    `include_geom=true` for passado. Assim o handler Lua já tem tudo.
  - **(B) Fallback bbox**: se `geom` não estiver disponível, usar
    `lat/lon + area_ha` para desenhar um círculo aproximado no mapa P5
    (raio = `sqrt(area_ha * 10000 / π)` metros). Menos preciso mas
    funcional.
  A geometria do imóvel (`property_geom`) vem de `car_lookup.get_by_cod_imovel`
  que já retorna `geom` (GeoJSON JSONB).
- Integration points: chama `render_risk_report.py <context.json> <out.pdf>`.
- **Derivação `id → cod_imovel`**: o `property_id` armazenado em `risk.db` é a
  chave surrogate (`cod_imovel` | `cnpj` | `lat:lon`). Para montar as seções
  cadastrais/eventos, o handler resolve `cod_imovel` a partir de `property_id`
  (se `property_id` for `cod_imovel`, usa direto; se for `cnpj`/`lat:lon`,
  tenta `car_lookup.get_by_cod_imovel`/`classify_point`; se não resolver, as
  seções espaciais ficam vazias com nota).
- **Orçamento do loop copas**: a montagem do `context.json` é leve (lookups em
  memória/índice, sem cruzamento espacial denso); o PDF pesado roda no
  subprocesso Python destacado.
- Error paths: algum lookup indisponível → seção omitida com nota, nunca
  falha o laudo inteiro.

##### scripts/data/render_risk_report.py (edit)
- What changes: estende para multi-página (identificação, eventos,
  sobreposições, histórico, evidências, mapa estático) consumindo
  `context.json`.
- Function(s): `render_report(context, out_path)` — adiciona seções:
  P1 capa, P2 executive summary, P3 identificação cadastral, P4 eventos,
  P5 sobreposições + mapa estático, P6 histórico/tendência, P7 recomendação,
  P8 evidências.
- **Mapa estático P5**: usa `context.geometries.property_geom` (GeoJSON do
  imóvel de `car_lookup`) e `context.geometries.alert_geoms` (GeoJSON/WKT
  dos alertas — via `mapbiomas_lookup` estendido ou fallback bbox).
  Renderiza com `matplotlib` (GeoPandas ou Shapely + descartes) sobre um
  fundo simples (sem tile fetch — offline). Camadas: imóvel (polígono),
  alertas (polígonos ou círculos bbox), UC/TI (de `protected[]`), APP/RL
  (se disponível). Salva como PNG embutido no PDF.
- Data shapes: input = `context.json` (acima, com `geometries`); output =
  PDF multi-página.
- Integration points: mantém branding Yvy; adiciona hash de auditoria no
  rodapé.
- Error paths: seção sem dados → omitida com nota; `geometries` ausente
  → P5 mostra nota "geometria indisponível" sem mapa; PDF excede 2MB →
  servir via download (Content-Disposition).

##### backend-lua/tests/test_risk_report.lua (edit)
- What changes: atualiza para o novo `context.json` + multi-página.
- Integration points: espelha o padrão existente (temp DB, `fake_ctx`).

#### Edge cases
- Imóvel sem alertas: seção eventos vazia com nota "sem alertas recentes".
- Imóvel sem embargo: seção embargo vazia com nota "sem embargo ativo".
- Área efetiva < área total do alerta: nota "X% do alerta fora do imóvel".
- Conflito fundiário (múltiplos CARs): nota na identificação cadastral.

#### Verification
- Run: `make test-lua` (busted), `python3 scripts/data/render_risk_report.py
  <context.json> <out.pdf>`
- Tests to add/update: `tests/test_risk_report.lua` (multi-página, seções
  omitidas, derivação `id → cod_imovel`), `tests/test_risk_score.lua` (área
  efetiva no fator, fallback para `recent_alerts`).
- Done: score usa área efetiva + embargo; laudo multi-página; testes passam.

### Inc 4 — Frontend laudo viewer + área efetiva (M)

**Depends on:** 3
**Unblocks:** none
**Done criteria:** a página `/risk-intelligence` mostra a área efetiva por
imóvel nos resultados do batch e um link de laudo enriquecido; teste de build
passa.

#### Files to touch

##### frontend/src/components/RiskIntelligence/RiskIntelligence.js (edit)
- What changes: a tabela de resultados mostra a **área efetiva** por imóvel
  (coluna "Área efetiva (ha)") e o link de PDF aponta para o laudo
  enriquecido.
- Function(s): `ResultsTable` — adiciona coluna de área efetiva; `PDF` link
  mantém `window.open('/api/risk/report?id=...')`.
- Data shapes: `GET /api/risk/batch?id=` retorna `area_efetiva_ha` por linha.
- Integration points: `cachedFetch`/`useCardData`; i18n `t('risk.*')`.
- Error paths: área efetiva ausente → mostra "—".

##### frontend/src/components/RiskIntelligence/RiskIntelligence.css (edit)
- What changes: estilo da nova coluna de área efetiva.
- Integration points: design tokens (`--surface-*`, `--border`, `--signal`).

#### Edge cases
- Batch com imóveis sem área efetiva: coluna mostra "—".
- Laudo enriquecido excede 2MB: link abre download em vez de inline.

#### Verification
- Run: `cd frontend && npm run build`
- Tests to add/update: build (CRA); sem testes unitários de frontend no repo.
- Done: página mostra área efetiva; laudo enriquecido acessível; build passa.

## Cross-cutting verification

- Após Inc 3, rodar um batch CSV de exemplo e abrir o laudo PDF: confirmar
  multi-página (identificação, eventos, sobreposições, histórico, evidências)
  e que a área efetiva aparece nos eventos.
- Após Inc 4, navegar `/risk-intelligence`, subir um CSV, verificar a coluna
  de área efetiva e o download do laudo enriquecido.
- Confirmar que o batch CSV de exemplo não excede o limite de **8MB** do
  nginx (`client_max_body_size 8m` em `/api/risk/`) — se exceder, o usuário
  precisa dividir o CSV ou subir o limite.

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` — aplica a: #1 (fixtures
  clock-relative `days_ago`), #2 (Redis isolado + teardown), #4 (schema
  upstream verificado em runtime), #5 (swap atômico + marker após sucesso).
- `.agents/AGENTS.md` — arquitetura, JSONB schema, deploy via Ansible.
- `.agents/DESIGN.md` — design tokens para o frontend.

## Open questions (CONSIDER from review)

- **Recency semantics**: `recent_alerts` é time-windowed (detecções recentes);
  `area_efetiva` é all-time. Substituir a entrada de desmatamento muda o
  significado do score além de "área efetiva". Decidir se `area_efetiva` deve
  ser windowed também (ex. só alertas dos últimos N dias) para manter a
  semântica de recência.
- **Propriedades não-CAR**: para `cnpj`/`lat:lon` não há `cod_imovel`, então
  as seções cadastrais/eventos/sobreposições do laudo ficam vazias. A rota
  precisa de um mapeamento `id → cod_imovel` explícito para esses casos (já
  esboçado em Inc 3; confirmar o fallback).
- **matplotlib/GeoPandas no prod**: o mapa estático P5 precisa de `matplotlib`
  (+ opcionalmente `geopandas`). Verificar se já está no `requirements.txt`
  do servidor, ou adicionar como dependência. Alternativa: desenhar com
  `reportlab` primitives (Shapes) + Shapely → sem depender de matplotlib.

## Out of scope

- SIGEF/SNCI multi-cadastral (conflito fundiário) — dataset não verificado;
  re-escopar quando a fonte for confirmada.
- CAR status monitoring (ativo/cancelado/suspenso + histórico) — requer schema
  change em `car_data`; dataset não verificado.
- Recomendação contextualizada por ICP (frigorífico/banco/fundo) — o score já
  tem pesos por ICP; a recomendação textual por persona é fase 2.
- White-label/client branding no laudo — adiado (single-tenant Yvy).
- Webhook durability (backoff, dead-letter) — fase 2.
- Multi-tenant auth/isolamento — fase 2.
