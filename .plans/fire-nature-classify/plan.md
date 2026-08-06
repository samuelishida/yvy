# Classificação Automática da Natureza do Fogo (Permitido/Natural vs Alertas Reais)

## Context

O backend do Yvy ingere focos do NASA FIRMS (tabela `fire_data`, ~159k linhas,
~19k nos últimos 7 dias) mas não diferencia **fogo permitido/manejo** de
**alerta real / crime ambiental**. O objetivo é classificar automaticamente a
natureza de cada foco cruzando as coordenadas FIRMS com:

- **A. Territorial** — TI/UC (já existem como camadas de polígonos) → máxima
  severidade; áreas privadas (CAR) → entram na fila temporal.
- **B. Temporal/Regulatório** — período de defeso/moratória do fogo (padrão
  jul–out, por estado) → queima 100% ilegal em terra privada; autorização
  Sinaflor (best-effort, via hook plugável).
- **C. Assinatura térmica** — novos campos do FIRMS (`fire_type`), `confidence`
  e `bright_ti4` para descartar alarmes falsos (ex: telhado metálico quente).

**Restrição central**: o backend é um único loop copas single-threaded —
qualquer cruzamento denso de polígonos dentro do loop trava TODAS as requests
(o cruzamento TI já mediu ~77s e foi movido para subprocesso). Logo, toda
classificação pesada roda em **subprocesso destacado** (padrão
`warm_ti_at_risk.lua`), nunca inline no loop.

**Resultado esperado**: cada foco em `fire_data` recebe `nature ∈ {crime,
suspeito, permitido, natural}` + evidência (por que foi classificado assim),
exposto no `/api/fires` e agregado em `/api/fires/nature-stats`, com backfill
retroativo dos focos existentes.

## Architectural decisions

- **Decision: `nature` como coluna escalar (não JSONB).** Rationale: o
  `bulk_upsert_fires` faz `ON CONFLICT ... DO UPDATE SET data=jsonb(excluded.data)`
  (db.lua:267-290) e **sobrescreveria** um `nature` guardado dentro do blob
  `data` a cada re-sync. Coluna separada sobrevive ao upsert. Alternativas
  rejeitadas: guardar em JSONB exigiria merge no upsert (mais complexo, risco
  de perda).
- **Decision: regra de classificação é 100% pura** (`fire_classify.lua`), o
  cruzamento territorial é feito pelo chamador (lookups) e injetado. Rationale:
  permite testes unitários com fixtures inline (padrão `test_geo.lua`) e
  reuso em subprocesso e loop. Alternativa rejeitada: acoplar lookups dentro da
  regra (não testável sem DB/polígonos reais).
- **Decision: backfill em subprocesso destacado com lock `setnx`**, espelhando
  `tools/warm_ti_at_risk.lua` + `trigger_ti_at_risk_refresh`. Rationale: o
  loop copas não pode rodar 19k+ cruza-mentos. Alternativa rejeitada: rodar no
  `state_backfill_loop` (mesma classe de bug já flagrada).
- **Decision: camada CAR em SQLite dedicado (`car.db`) com índice espacial
  nativo RTree + geometria em JSONB.** Rationale: medido no piloto, só Rondônia
  ≈ 0,5GB em memória (194k imóveis, ~2M vértices) e o Brasil tem ~7M imóveis —
  grade em memória estouraria a VM de 1GB. **Verificado no SQLite instalado
  (3.45.1 via lsqlite3): módulo `rtree` e `jsonb()` disponíveis** → arquivo
  separado (`CAR_DB_PATH`, default `backend-lua/data/car/car.db`) com `car_data`
  (geom como **JSONB BLOB**) + `car_rtree` (virtual table rtree, verdadeiro
  índice 2D); `classify_point` faz query rtree (bbox) → decodifica só os
  candidatos → ray-cast. RTree é estritamente melhor que a grade manual (sem
  lógica de células/vizinhos, query nativa); grade `car_cell` fica como
  **fallback documentado** se alguma deploy não tiver rtree. Alternativas
  rejeitadas: grade em memória (não escala), `lookup_data` JSONB (blob de ~7M
  inviável).
- **Decision: moratória como configuração em código por estado (padrão
  jul–out), Sinaflor como hook plugável que hoje retorna "sem dado → não
  autorizado".** Rationale: sem fonte pública de decretos/ano nem API Sinaflor
  disponível. Alternativa rejeitada: tentar scrape (frágil, fora de escopo).
- **Decision: pipeline em 4 passos** — (1) TI/UC → crime (máxima severidade,
  ANTES do descarte térmico — sinal fraco em área protegida é provável queima
  pequena real, não alarme falso) → (2) térmico descarta alarme fraco →
  (3) CAR/privado → janela de defeso (crime) senão autorização (permitido)
  senão suspeito → (4) sem território: defeso → suspeito; senão natural.
- **Decision: reclassificação rastreável por `nature_version`.** O filtro
  rotineiro é `nature IS NULL` (fast path); quando o CAR carrega (Inc 6) ou a
  config de moratória muda, bump de versão dispara reclassificação de focos já
  classificados (`nature_version < ?`). Sem isso, re-run do backfill seria no-op
  e a revisão anual de moratória não recomputaria nada.

## Assumptions and answers from code

- Decision: FIRMS retorna hoje coluna `fire_type` no CSV sem parâmetro extra —
  basta parsear e persistir. Source: code @ `fires.lua:88-113` (colunas atuais
  parseadas: lat/lon/confidence/acq_date/acq_time/satellite/bright_ti4; `frp`,
  `daynight`, `fire_type` são descartadas). **Atenção (verificado na revisão):**
  o `fire_type` do VIIRS tende a ser categórico numérico (ex: 0/1/2/4 =
  other/volcano/offshore/agriculture) e o `confidence` pode chegar numérico
  (não só `"low"`) — capturar amostra real do CSV no Inc 1 e fixar os domínios
  antes de confiar nos ramos térmicos.
- Decision: `fire_data` schema atual (escalares lat/lon/acq_date/ingested_at +
  JSONB `data`: confidence/acq_time/satellite/bright_ti4/source/state). Source:
  code @ `db.lua:45-49,78-95,279-290`.
- Decision: lookups TI (547) e UC (298) existem com `classify_point(lon,lat)`
  e bbox reject (TI). Source: code @ `app/lookups/indigenous_lands_lookup.lua:100-116`,
  `conservation_units_lookup.lua:81-92`, `geo.lua:3-42`.
- Decision: NÃO existe nenhuma camada CAR, nem dados de moratória/defeso, nem
  Sinaflor no repo. Source: grep `CAR|sinaflor|defeso|morat|autoriz|queima` →
  só falsos positivos. **CAR agora vem do GeoServer oficial do CAR via WFS**
  (`sicar:sicar_imoveis_<uf>`, scriptável, sem captcha) —
  `scripts/download_car_wfs.py` baixou RO (194.352 imóveis, 150,7MB; 73,9% dos
  focos RO caem em CAR) e o download dos 27 estados está em andamento
  (user-confirmed). **Armazenamento: SQLite dedicado (`car.db`) com RTree +
  JSONB** (user-confirmed; `rtree`/`jsonb` verificados disponíveis no SQLite
  3.45.1 instalado).
- Decision: padrão de subprocesso pesado existe e é canônico
  (`compute_ti_at_risk` + `trigger_ti_at_risk_refresh` + `tools/warm_ti_at_risk.lua`
  + lock `setnx` + cache `:stale`). Source: code @ `fires.lua:269-351`,
  `redis.lua:171-183`, `tools/warm_ti_at_risk.lua`.
- Decision: templates de backfill: `iter_fires_for_backfill` + `state_backfill_loop`.
  Source: code @ `db.lua:503-520`, `init.lua:203-225`.
- Decision: taxonomia de 4 classes `crime/suspeito/permitido/natural`
  (user-confirmed). Moratória por estado + hook Sinaflor plugável
  (user-confirmed). Backfill retroativo + campo no `/api/fires` + endpoint
  `nature-stats` (user-confirmed).
- Decision: testes usam **busted** (`make test-lua` = `cd backend-lua && busted
  --verbose tests/*.lua`), glob `tests/*.lua`, DB temporário de arquivo com
  `env.set("SQLITE_PATH", ...)` + `package.loaded["app.db"]=nil` re-require.
  Source: code @ `tests/test_db.lua:5-20`, `Makefile:29`, `.busted`.
- Decision: `luac -p` roda no CI sobre todo `.lua` não-teste. Source: code @
  `.github/workflows/ci.yml:55-60`.

## Risks accepted

- **Custo do backfill retroativo (milhões de focos × 547 TI + 298 UC + CAR)**: rodar
  em subprocesso, batches de 500 com **uma transação por batch**
  (`update_fire_natures(rows)`), filtro `nature IS NULL OR nature_version < ?`
  (idempotente), índice em `nature`. Aceito; revisit se >1h.
- **Reclassificação**: o CAR carrega depois do primeiro backfill → bump de
  `nature_version` recomputa os focos afetados (guard por versão, não por NULL).
  Aceito: custo de recomputar ≈ backfill inicial.
- **Escala CAR (milhões de imóveis, ~7M no Brasil)**: armazenado em `car.db`
  com **RTree** (query bbox nativa) + **geom JSONB** — só candidatos em memória
  (validado: RO 194k imóveis → 73,9% dos focos em CAR). Se algum deploy não
  tiver rtree, fallback grade `car_cell`. Import em lote offline com
  `synchronous=OFF` + VACUUM/ANALYZE.
- **Janelas de moratória aproximadas (decretos variam por ano/estado)**: valores
  em configuração por estado, revisados anualmente; documentado como
  aproximado. Falso negativo (queima legal em janela) é aceito; falso positivo
  (crime) evitado ao máximo.
- **`fire_type` do FIRMS pode ser vazio/impreciso**: tratado como sinal, nunca
  como prova; `bright_ti4` nulo não descarta (default forte) para não derrubar
  foco real.
- **Sem dado Sinaflor → "não autorizado"**: conservador, gera `suspeito` (não
  `crime`) fora da moratória — não acusa crime sem base.
- **Overwrite de `nature` no re-sync**: mitigado por coluna escalar separada
  (decision acima).
- **Concorrência backfill × sync**: lock `setnx` + WAL; um único processo
  escreve por vez.

## Otimizações SQLite (aplicadas por tabela)

Princípio: só aplicar onde faz sentido — a decisão por tabela está abaixo. O
SQLite instalado (3.45.1 via lsqlite3) tem `rtree`, `jsonb()`, `WITHOUT ROWID`
(verificado).

| Tabela / DB | Otimização | Onde no plano |
|---|---|---|
| `fire_data` (yvy.db) | JSONB `data` + expression indexes (confiança, estado, fire_type); `nature`/`nature_version` como **escalares** com índice composto (`nature, nature_version`); índice composto `acq_date, nature` p/ stats; WAL/synchronous=NORMAL/cache_size/temp_store (já no `pool_acquire` de `db.lua`) + **`mmap_size`**; `PRAGMA optimize` pós-backfill | Inc 1, Inc 3 |
| `lookup_data` (yvy.db) | JSONB blob + in-memory no startup (TI/UC são pequenos: 547/298 polígonos) — **sem mudança**; se um dia crescer, aplicar o mesmo padrão RTree+JSONB do CAR | — |
| `car.db` (novo) | RTree (índice espacial nativo) + geom JSONB + WAL/mmap + import bulk (`synchronous=OFF`, `wal_checkpoint(TRUNCATE)`, `VACUUM`, `ANALYZE`, `PRAGMA optimize`) | Inc 6 |
| `deforestation_data`, `news` | Fora do escopo desta feature (PRODES e notícias) — não alterar | — |

Padrões compartilhados (reaproveitados do que já existe em `db.lua`):
- **JSONB**: `jsonb(?)` no write, `json()`/`json_extract` no read — nunca
  decodificar o blob cru (gotcha AGENTS.md).
- **Índices**: expression index para campos consultados em filtro/GROUP BY;
  índice **composto** quando o query combina colunas (ex: `acq_date, nature`);
  índice em coluna escalar para o filtro `nature IS NULL` (fast path do backfill).
- **Conexões**: leitura pesada → `mmap_size`; bulk write → `synchronous=OFF`
  numa transação; depois `wal_checkpoint(TRUNCATE)` + `VACUUM` + `ANALYZE` +
  `PRAGMA optimize`.
- **Tabela de mapeamento puro** (chave composta, sem colunas avulsas):
  `WITHOUT ROWID` (ex: fallback `car_cell`).

## Increment DAG

- Inc 1 — FIRMS ingest extension (S) — depends: none — unblocks: 2 (fire_type p/ térmico), 4
- Inc 2 — Classifier core + tests (S) — depends: none — unblocks: 4, 6
- Inc 3 — Schema + DB layer (M) — depends: none — unblocks: 4, 5, 6
- Inc 4 — Backfill subprocess + trigger + loop (M) — depends: 1, 2, 3 — unblocks: 5
- Inc 5 — API: nature em /api/fires + nature-stats (M) — depends: 3, 4 — unblocks: 7
- Inc 6 — CAR layer + índice espacial RTree (L) — depends: 2, 3 — unblocks: (re-run 4 com CAR)
- Inc 7 — Frontend: natureza no mapa + painel (S, opcional) — depends: 5 — unblocks: none

Sequenciamento: Inc 1 e Inc 3 **ambos editam `db.lua` + `tests/test_db.lua`** →
não aterrissam em paralelo sem rebase (aterrissar 1, depois 3, ou reordenar).
Inc 2 é totalmente paralelo à onda 1–3. Depois **4** (usa 1+2+3), **5**
(usa 3+4), **6** (usa 2+3, paralelo a 4/5), **7** (usa 5).

## Increments

### Inc 1 — Ingestão FIRMS: persistir fire_type, frp, daynight (S)

**Depends on:** none
**Unblocks:** 2 (fire_type melhora o térmico), 4 (dados de qualidade)
**Done criteria:** foco syncado tem `fire_type`/`frp`/`daynight` persistidos no JSONB e retornados pela API; testes passam.

#### Files to touch

##### backend-lua/app/routes/fires.lua
- What changes: mapeamento de colunas CSV em `fetch_firms_data` (linhas 99-113)
  passa a ler `fire_type`, `frp`, `daynight`.
- Function(s): `fetch_firms_data(global_sync)` — no row-mapping adicionar:
  ```lua
  fire_type = (row.fire_type or ""):lower(),   -- "vegetation"|"other"|"" (string crua normalizada)
  frp       = tonumber(row.frp or 0) or 0,     -- Fire Radiative Power (MW)
  daynight  = (row.daynight or ""):upper(),    -- "D"|"N"|""
  ```
- Data shapes: doc adiciona `{fire_type="vegetation", frp=245.3, daynight="D"}`.
- Integration points: `db.bulk_upsert_fires(docs)` recebe os campos novos.
- Error paths: coluna ausente no CSV (API antiga) → default `""`/`0`/`""`;
  `tonumber` falha → `0`.

##### backend-lua/app/db.lua
- What changes: `bulk_upsert_fires` grava os 3 campos novos no objeto JSONB
  (279-290); `rows_to_fires` (296-313) os devolve; índice de expressão novo.
- Function(s):
  - `bulk_upsert_fires(docs)`: `data` ganha `fire_type, frp, daynight`.
  - `rows_to_fires(rows)`: retorno ganha `fire_type, frp, daynight`.
  - `init_db()`: `CREATE INDEX IF NOT EXISTS idx_fire_fire_type ON fire_data(json_extract(data,'$.fire_type'))`.
- Data shapes: `rows_to_fires` → `{lat, lon, confidence, acq_date, acq_time,
  satellite, bright_ti4, fire_type, frp, daynight, ...}`.
- Integration points: chamadores atuais (rotas `fires`) são nil-safe a campos
  novos.
- Error paths: foco sem fire_type (nil) → `""`; JSONB round-trip via
  `json(data)` (nunca decodificar blob cru — gotcha do AGENTS.md).

##### backend-lua/tests/test_db.lua
- Add: `bulk_upsert_fires` com fire_type/frp/daynight → `find_fires` devolve;
  round-trip JSONB; foco sem os campos → defaults.

#### Edge cases
- Coluna `fire_type` ausente no CSV / resposta antiga da NASA: default `""`.
- `frp` em formato com vírgula ou vazio: `tonumber` → `0`.
- Foco duplicado (lat/lon/acq_date): upsert atualiza `data` e mantém os campos.

#### Verification
- Run: `make test-lua`; `luac -p backend-lua/app/routes/fires.lua backend-lua/app/db.lua`.
- Tests to add/update: `test_db.lua` (round-trip dos 3 campos).
- Manual: `POST /api/fires/sync` → `GET /api/fires` mostra fire_type/frp/daynight.
- Done: `fire_data` persiste e a API retorna os 3 campos.

### Inc 2 — Núcleo do classificador puro + testes (S)

**Status:** DONE (2026-08-06) — `app/fire_classify.lua` + `tests/test_fire_classify.lua` (19 testes, make test-lua verde)
**Depends on:** none
**Unblocks:** 4, 6
**Done criteria:** `fire_classify.classify_fire` retorna as 4 classes corretas
para todos os casos de fixture; `make test-lua` verde.

#### Files to touch

##### backend-lua/app/fire_classify.lua (NEW)
- What changes: módulo puro (zero I/O) com a regra de classificação.
- Function(s):
  ```lua
  _M.DEFAULT_CONFIG = {
    thermal = { confidence_weak = {"low"}, confidence_weak_num = 20,
                bright_ti4_weak = 310.0,
                fire_type_industrial = {},  -- valores reais do VIIRS a fixar no Inc 1 (amostra CSV)
                fire_type_industrial_num = {} },
    moratorium = { months = {7,8,9,10}, by_state = {} },  -- RO = {months={7,8,9,10}} etc.
    sinaflor = nil,   -- hook plugável: fn(car_prop, acq_date) -> bool|nil
  }
  _M.is_moratorium(state_abbr, acq_date, cfg) -> boolean
  _M.thermal_weak(confidence, bright_ti4, fire_type, cfg) -> boolean
  -- confidence: aceita "low"/"nominal"/"high" OU numérico (<confidence_weak_num = fraco)
  -- fire_type: numérico ou string; ramo industrial só ativo com valores conhecidos em cfg
  _M.classify_fire(fire, territory, cfg) -> {nature, evidence}
  ```
  - `fire` = `{lon, lat, acq_date, state, confidence, bright_ti4, fire_type}`
    (`bright_ti4`/`fire_type` nil-safe).
  - `territory` = `{indigenous = name|nil, conservation = name|nil, car = {name,id}|nil}`
    (pré-computado pelo chamador via lookups).
  - Regras (ordem):
    1. TI/UC presente → `{nature="crime", evidence={territory={tipo, nome},
       moratorium=is_moratorium(...)}}` (máxima severidade; **antes do térmico** —
       sinal fraco em área protegida não é alarme falso). Moratória só entra
       como evidência.
    2. `thermal_weak` → `{nature="natural", evidence={thermal_weak=true,
       reason="baixo sinal térmico / possível alarme falso"}}` — cobre CAR e
       terra sem território (falso alarme não vira crime).
    3. `territory.car` presente:
       - `is_moratorium(state, acq_date)` → `{nature="crime",
         evidence={car={name,id}, moratorium=true}}` (100% ilegal).
       - senão: `auth = cfg.sinaflor and cfg.sinaflor(car, acq_date)`.
         `auth` → `{nature="permitido", evidence={authorization=true}}`;
         senão → `{nature="suspeito", evidence={car=..., no_authorization=true}}`.
    4. Sem território: `is_moratorium` → `{nature="suspeito",
       evidence={moratorium=true}}`; senão `{nature="natural", evidence={}}`.
  - `_M.is_moratorium`: parse de "YYYY-MM-DD" manual (sem os.date por
    determinismo), mês ∈ `by_state[state]` senão `months` global.
- Data shapes: `classify_fire` → `{nature="crime"|"suspeito"|"permitido"|"natural",
  evidence={...}}`.
- Integration points: chamado por `tools/classify_fires.lua` (Inc 4) e testes.
  Nenhuma rota chama direto.
- Error paths: `acq_date` malformado → não-moratória (seguro); `state=""` →
  janela global; `bright_ti4=nil` → NÃO fraco (não derruba foco real).

##### backend-lua/tests/test_fire_classify.lua (NEW)
- What changes: busted com fixtures inline (padrão `test_geo.lua`).
- Testes: `is_moratorium` (dentro/fora/override por estado); `thermal_weak`
  (low conf / conf numérica baixa / low bright_ti4 / fire_type industrial /
  nil-safe); `classify_fire` (TI+moratória→crime, TI fora→crime, **TI + sinal
  fraco → crime** [TI precede o térmico], CAR+moratória→crime, CAR
  fora+autorizado via stub→permitido, CAR fora sem hook→suspeito, sem
  território+moratória→suspeito, sem território fora→natural, térmico fraco em
  terra sem território→natural).

#### Edge cases
- Foco com `state` vazio: janela global de moratória.
- Sobreposição TI ∩ CAR: TI/UC tem precedência (crime).
- `fire_type` desconhecido: ignorado pelo térmico (só match positivo).

#### Verification
- Run: `make test-lua` (glob `tests/*.lua` pega o arquivo novo); `luac -p`.
- Tests to add/update: `test_fire_classify.lua` (todos os casos acima).
- Done: matriz de casos de fixture verde; regra 100% pura.

### Inc 3 — Schema + camada de banco para nature (M)

**Depends on:** none
**Unblocks:** 4, 5, 6
**Done criteria:** `fire_data` ganha colunas `nature`/`nature_evidence`/`nature_at`
(com auto-migration), funções de gravar/iterar/contar com testes; re-sync não
apaga nature.

#### Files to touch

##### backend-lua/app/db.lua
- What changes: migração aditiva + funções de persistência/leitura de nature.
- Function(s):
  ```lua
  -- SCHEMA: adicionar as colunas novas TAMBÉM na CREATE TABLE (instalações novas
  -- ficam self-describing); o ALTER abaixo cobre DB legado:
  --   nature TEXT, nature_evidence BLOB, nature_at TEXT, nature_version INTEGER DEFAULT 0
  -- init_db(): PRAGMA table_info(fire_data) → se sem 'nature':
  --   ALTER TABLE fire_data ADD COLUMN nature TEXT;
  --   ALTER TABLE fire_data ADD COLUMN nature_evidence BLOB;  -- JSONB
  --   ALTER TABLE fire_data ADD COLUMN nature_at TEXT;        -- ISO
  --   ALTER TABLE fire_data ADD COLUMN nature_version INTEGER DEFAULT 0;
  --   CREATE INDEX IF NOT EXISTS idx_fire_nature ON fire_data(nature, nature_version);
  --   CREATE INDEX IF NOT EXISTS idx_fire_acqdate_nature ON fire_data(acq_date, nature);
  --     (count_fires_by_nature filtra por acq_date e agrupa por nature)

  -- NATURE_VERSION: constante única da versão da regra (env FIRE_NATURE_VERSION,
  -- default 1), definida em fire_classify.lua (junto da config de moratória).
  -- Bump manual (ex: 2) quando o CAR importa (Inc 6) ou a moratória muda →
  -- reclassifica os focos com nature_version < NATURE_VERSION.

  _M.update_fire_natures(rows, version)            -- batch: 1 transação por lote de 500
      -- rows = { {id, nature, evidence, at}, ... }
      -- UPDATE fire_data SET nature=?, nature_evidence=jsonb(?), nature_at=?, nature_version=? WHERE id=?
      -- version = EXATAMENTE o min_version usado na seleção (rotina: 0; reclassify: NATURE_VERSION)
  _M.iter_fires_for_classification(batch_size, min_version)
      -- SELECT id, lat, lon, acq_date,
      --   json_extract(data,'$.state') as state, json_extract(data,'$.confidence') as confidence,
      --   json_extract(data,'$.bright_ti4') as bright_ti4, json_extract(data,'$.fire_type') as fire_type
      -- FROM fire_data WHERE (nature IS NULL OR nature_version < ?) AND acq_date IS NOT NULL
      -- ORDER BY id LIMIT ?
      -- min_version:
      --   = 0 (rotina / fast path) → só nature IS NULL (nature_version >= 0 nunca < 0)
      --   = NATURE_VERSION (reclassify pós-CAR/moratória) → nature_version < NATURE_VERSION + NULLs
  _M.count_unclassified()                          -- SELECT 1 ... nature IS NULL LIMIT 1 (cheap)
  _M.count_fires_by_nature(days, state)            -- WHERE acq_date >= date('now','-N days')
      --   [AND json_extract(data,'$.state') = ?] GROUP BY COALESCE(nature,'unclassified')
      -- → {crime=n, suspeito=n, permitido=n, natural=n, unclassified=n}
  _M.count_fires_by_nature_by_state(days)          -- GROUP BY COALESCE(json_extract(data,'$.state'),''), COALESCE(nature,'unclassified')
  ```
- Data shapes: `nature` ∈ nil|`crime`|`suspeito`|`permitido`|`natural`;
  `nature_evidence` = JSONB do objeto `evidence` (cjson.encode → `jsonb(?)`).
- Integration points: `find_fires` e `find_fires_since` passam a selecionar
  `nature, nature_at` (e expor `nature_evidence` via `json()` quando usado);
  `rows_to_fires` adiciona `nature` (nil-safe) ao retorno → `/api/fires` herda
  automaticamente. `bulk_upsert_fires` NÃO mexe nas colunas novas (scalar
  separado) → re-sync preserva nature (decisão-chave).
- Otimizações no pool compartilhado (`db.lua` `pool_acquire`): adicionar
  `PRAGMA mmap_size` (leitura pesada de `fire_data`), mantendo
  WAL/synchronous/cache_size/temp_store atuais; rodar `PRAGMA optimize` após o
  backfill (Inc 4) para o planner usar os índices novos (ver seção
  "Otimizações SQLite").
- Error paths: migração em DB já migrado → guard por `PRAGMA table_info`;
  evidence cjson.encode falha → gravar `nature` sem evidence.

##### backend-lua/tests/test_db.lua
- Add: migração adiciona colunas em schema legado + SCHEMA já as declara;
  `update_fire_natures` round-trip em batch (ler via `json(nature_evidence)` +
  `nature_version`); `iter_fires_for_classification` sem `min_version` → só
  `nature IS NULL`, com `min_version>0` → também reclassificáveis;
  `count_fires_by_nature` agrupa certo (incl. NULL → unclassified);
  `bulk_upsert_fires` após classificação NÃO apaga nature.

#### Edge cases
- Backfill concorrente com sync: WAL; escritor único por vez (lock do Inc 4).
- `nature` NULL = não classificado (contado em `unclassified`).
- Foco re-ingestido (mesmo lat/lon/acq_date): DO UPDATE só toca `data`/`ingested_at`.

#### Verification
- Run: `make test-lua`; `luac -p`.
- Manual: subir backend, `PRAGMA table_info(fire_data)` mostra colunas novas.
- Done: colunas existem em DB novo e legado; re-sync preserva nature.

### Inc 4 — Backfill em subprocesso + trigger + loop (M)

**Status:** DONE (2026-08-06) — `tools/classify_fires.lua` + `trigger_fire_classification(version)` + rota `POST /api/admin/fires/classify` + `nature_backfill_loop`; smoke test: 3 focos classificados corretamente (v0)
**Depends on:** 1, 2, 3
**Unblocks:** 5
**Done criteria:** focos não-classificados ganham `nature` numa passada de
backfill destacado (nunca bloqueia o loop); `POST /api/admin/fires/classify`
inicia o job.

#### Files to touch

##### backend-lua/tools/classify_fires.lua (NEW)
- What changes: subprocesso standalone (padrão `warm_ti_at_risk.lua`).
- Function(s): `main()` — carrega `app.env`, `app.db` (`init_db`), lookups
  (`ti`, `uc`; `car` se carregado), `fire_classify`; loop:
  ```lua
  local version = tonumber(arg and arg[1]) or 0   -- rotina=0; reclassify=NATURE_VERSION (via --version)
  local batch = db.iter_fires_for_classification(500, version)
  if #batch == 0 then break end
  local rows = {}
  for each row:
    local territory = {
      indigenous    = ti.classify_point(row.lon, row.lat),
      conservation  = uc.classify_point(row.lon, row.lat),
      car           = car_loaded and car.classify_point(row.lon, row.lat) or nil,
    }
    local res = fire_classify.classify_fire(row, territory)
    if res.nature then rows[#rows+1] = {id=row.id, nature=res.nature, evidence=res.evidence, at=now_iso()} end
  db.update_fire_natures(rows, version)          -- 1 transação por batch; grava a MESMA versão do filtro
  -- log: "classified N fires (crime=.., suspeito=.., ...) in Xs"
  -- ao final:
  --   redis.delete_pattern("fires:nature:*")     -- stats (nature-stats)
  --   redis.delete_pattern("firescache:*")       -- OBRIGATÓRIO: /api/fires tem cache de 60s
  --   redis.set("fires:classify:last_run", cjson({count, duration, by_nature, version}), 86400)
  ```
- Integration points: chamado por `nohup lua5.1` via trigger; escreve direto
  no DB (não Redis).
- Error paths: DB lockado → pcall + retry curto; crash no meio → retoma na
  próxima execução (`nature IS NULL OR nature_version < ?`).

##### backend-lua/app/routes/fires.lua
- Function(s): `_M.trigger_fire_classification(version)` — `setnx("fires:classify:lock",
  now, 1800)` (TTL proporcional ao backfill ~159k linhas — 120s expiraria no
  meio e spawnaria jobs duplicados); se não adquiriu → `{started=false}`; senão
  deriva `backend_dir` de `debug.getinfo(1,"S").source` e spawna com **branch
  dual Windows/MSYS2** (copiar de `trigger_ti_at_risk_refresh`, `fires.lua:336-345`),
  passando `version` como argumento do tool:
  - Windows: `start /b lua5.1.exe "<backend>\\tools\\classify_fires.lua" <version> ...`
  - Unix: `nohup lua5.1 "<backend>/tools/classify_fires.lua" <version> >/dev/null 2>&1 &`
  (pcall(os.execute)); retorna `{started=true}`.

##### backend-lua/main.lua
- What changes: nova rota `POST /api/admin/fires/classify?version=N` →
  `auth.enforce` → `rl.enforce` → `trigger_fire_classification(version)` → 200
  `{started}`. `version` opcional (default 0 = rotina); reclassify = passar a
  `NATURE_VERSION` corrente.

##### backend-lua/app/init.lua
- What changes: `nature_backfill_loop` — a cada `FIRE_CLASSIFY_INTERVAL=600`s:
  `if db.count_unclassified() and trigger_fire_classification()`; registrado em
  `start_background_tasks`.
- Error paths: lock ativo (job rodando) → skip; `count_unclassified` barato
  (LIMIT 1, índice em `nature`). Lock TTL 1800s cobre o job inteiro; se ainda
  expirar, a idempotência (`nature_version`) impede corrupção.

#### Edge cases
- Concorrência: lock `setnx` impede 2 jobs; retomada idempotente.
- Backfill enorme (159k+): batches de 500, commit por batch, executa em
  segundos/minutos fora do loop.
- `car` ainda não carregado (Inc 6 pendente) → `territory.car=nil` (comporta
  como sem território).

#### Verification
- Run: `make test-lua`; `luac -p` em todos os arquivos.
- Manual: subir backend → `POST /api/admin/fires/classify` → conferir o marcador
  Redis `fires:classify:last_run` (count/duration/by_nature/version) e
  `SELECT COUNT(*) FROM fire_data WHERE nature IS NULL` diminuindo; `GET
  /api/fires` passa a ter `nature` preenchido (o cache `firescache:*` é
  invalidado ao fim do job).
- Done: backfill roda destacado, popula nature e grava o marcador Redis
  `fires:classify:last_run` sem travar o loop.

### Inc 5 — API: nature em /api/fires + /api/fires/nature-stats (M)

**Status:** DONE (2026-08-06) — `get_fire_nature_stats` + rota `GET /api/fires/nature-stats` (cache Redis, valida estado); smoke: 22.492 focos/365d, por estado
**Depends on:** 3, 4
**Unblocks:** 7
**Done criteria:** `/api/fires` retorna `nature` por foco; `/api/fires/nature-stats?days&state`
retorna distribuição (nacional e por estado), cacheado em Redis.

#### Files to touch

##### backend-lua/app/routes/fires.lua
- What changes: `rows_to_fires` já devolve `nature` (Inc 3) → `/api/fires`
  herda. Nova função de stats.
- Function(s):
  ```lua
  _M.get_fire_nature_stats(days, state) -> {
    days, state,
    total = n,
    classes = {crime=.., suspeito=.., permitido=.., natural=.., unclassified=..},
    by_state = { {state="RO", total=.., crime=.., suspeito=.., permitido=.., natural=..} , ... },
  }
  ```
  - `days` nil → default 7; `state` opcional (valida contra `state_lookup.list_ufs()`).
  - Compõe de `count_fires_by_nature` + `count_fires_by_nature_by_state`.
- Integration points: chamado pela rota em `main.lua`; usa `state_lookup`.

##### backend-lua/main.lua
- What changes: rota `GET /api/fires/nature-stats?days&state` → `auth` →
  `rl` → `redis.get("fires:nature:<days>[:<STATE>]")` cache hit; senão
  `get_fire_nature_stats` → `redis.set(key, body, 300)` + `Cache-Control
  max-age=60`. Sem bloqueio (stats são SQL agregado, leve).

#### Edge cases
- `days=0` → tudo (cuidado com contagem pesada; cap default 7/30/90).
- Estado inválido → 400 (valida via `state_lookup.list_ufs()`).
- Dados vazios / nenhum classificado → classes zeradas, `unclassified=total`.

#### Verification
- Run: `make test-lua`; `luac -p`.
- Manual: `curl /api/fires/nature-stats?days=7` → JSON com classes; `curl
  /api/fires` → focos com `nature`.
- Done: endpoints retornam distribuição e campo por foco.

### Inc 6 — Camada CAR + índice espacial em SQLite (L)

**Status:** DONE (2026-08-06) — `car_lookup` (RTree+JSONB) + `car_import` + `tools/import_car.lua` + `test_car_lookup`; RO importado (194.352 imóveis, 86MB) e validação real: 17/23 focos RO (73,9%) em CAR
**Depends on:** 2, 3 (precisa de `nature_version` p/ reclassificação)
**Unblocks:** re-run do Inc 4 com `territory.car` preenchido
**Done criteria:** `car_lookup` consulta `car.db` (tabelas `car_data` + `car_cell`,
carregadas por import do GeoJSON), classifica coordenadas via célula+bbox+ray-cast,
integra com `classify_fire`; testes com fixture; **bump de `nature_version`**
dispara reclassificação dos focos anteriores.

#### Files to touch

##### backend-lua/app/lookups/car_lookup.lua (NEW)
- What changes: lookup espacial em SQLite dedicado (memória baixa; só candidatos
  decodificados por query). Fonte: `backend-lua/data/car/<UF>.json` (GeoJSON
  FeatureCollection, baixado por `scripts/download_car_wfs.py`).
- Function(s):
  ```lua
  _M.load_car()               -- abre car.db (CAR_DB_PATH, default backend-lua/data/car/car.db);
                              -- se vazio → warning (não quebra; territory.car = nil)
                              -- conexão (pool próprio, só leitura): journal_mode=WAL,
                              -- synchronous=NORMAL, cache_size=-8000, temp_store=MEMORY,
                              -- mmap_size=268435456 (256MB)
  _M.count() -> n             -- SELECT COUNT(*) FROM car_data
  _M.classify_point(lon, lat) -> {id=cod_imovel, name=municipio, uf}|nil
  _M.is_private(lon, lat) -> boolean
  ```
- Esquema (criado em `car.db` por `db.init_car()` — verificado no SQLite 3.45.1
  instalado: `rtree` e `jsonb()` disponíveis):
  ```sql
  CREATE TABLE IF NOT EXISTS car_data (
    id INTEGER PRIMARY KEY,                  -- liga ao rtree
    cod_imovel TEXT UNIQUE NOT NULL,         -- código CAR (dedup)
    uf TEXT NOT NULL,
    municipio TEXT,
    area REAL,                               -- ha, p/ tie-break "maior área"
    geom BLOB                                -- geometria (Polygon/MultiPolygon) em JSONB: jsonb(?) no insert
  );
  CREATE VIRTUAL TABLE IF NOT EXISTS car_rtree USING rtree(
    id, minLon, maxLon, minLat, maxLat       -- índice espacial nativo 2D
  );
  -- fallback (só se a deploy não tiver rtree):
  --   CREATE TABLE car_cell (cell TEXT, car_id INTEGER, PRIMARY KEY(cell, car_id)) WITHOUT ROWID;
  --   + colunas min_lon/min_lat/max_lon/max_lat em car_data p/ a grade
  ```
- `classify_point(lon, lat)`: `SELECT id FROM car_rtree WHERE minLon<=? AND
  maxLon>=? AND minLat<=? AND maxLat>=?` → ids candidatos → `SELECT id, uf,
  municipio, area, json(geom) AS g FROM car_data WHERE id IN (...)` (nunca ler o
  blob cru — gotcha JSONB) → `cjson.decode(g)` → `geo.point_in_polygon` → match
  de **maior área** (tie-break em `evidence`).
- Integration points: `tools/classify_fires.lua` (Inc 4) carrega `car` se
  presente e injeta em `territory.car`; `fire_classify` já recebe
  `territory.car` (Inc 2) — sem mudança de regra. Ao importar/atualizar a base,
  bump `NATURE_VERSION` (ex: +1) para recompute dos focos antigos.
- Error paths: `car.db` ausente/vazio → lookup vazio (foco sem território → não
  força fila temporal); linha com `geom` malformado → skip com warn.

##### backend-lua/tools/import_car.lua (NEW)
- What changes: import offline do GeoJSON → `car.db` (ETL one-shot; roda no dev,
  não no loop copas).
- Function(s): `main()` — abre `car.db` (cria schema), para cada
  `backend-lua/data/car/<UF>.json`: parse `cjson` (FeatureCollection), computa
  bbox por imóvel, arredonda coords a 5 decimais (~1m) p/ encolher o geom,
  insere `car_data` (geom via `jsonb(?)`) + `car_rtree` (bbox); `BEGIN/COMMIT`
  por UF com `synchronous=OFF` durante o bulk load; log "imported <UF>: N
  imóveis". Ao final: `PRAGMA wal_checkpoint(TRUNCATE)` + `VACUUM` + `ANALYZE`
  + `PRAGMA optimize`.
- Integration points: gerado a partir dos dumps do `scripts/download_car_wfs.py`;
  o `car.db` resultante é copiado no deploy (ver cross-cutting).
- Error paths: GeoJSON malformado → skip do arquivo com warn; reimport →
  `DELETE FROM car_data; DELETE FROM car_rtree` antes (idempotente).

##### backend-lua/tests/test_car_lookup.lua (NEW) + tests/fixtures/car_sample.json
- What changes: fixture com 3 imóveis minúsculos (um cruzando borda de célula) em
  um `car.db` temporário (padrão `test_db.lua`: `env.set("CAR_DB_PATH", tmp)` +
  `package.loaded["app.car_lookup"]=nil` + re-require); roda `import_car` sobre a
  fixture antes do teste.
- Testes: dentro/fora/na borda (rtree); `count()`; `car.db` vazio → count 0;
  `is_private`; match por maior área em sobreposição; fallback grade se rtree
  indisponível.

#### Edge cases
- Polígono cruzando o bbox do rtree: o rtree indexa o bbox do imóvel → coberto
  pela própria indexação (sem lógica de vizinhos).
- Sobreposição de imóveis CAR: match de **maior área**, tie-break em `evidence`.
- `uf` do imóvel usado na regra de moratória quando `fire.state` vazio.
- Reclassificação: `nature_version` garante que focos em CAR recém-importado
  sejam recomputados (senão re-run seria no-op).
- Deploy sem rtree (incomum; SQLite 3.45.1 tem): fallback grade `car_cell`.

#### Verification
- Run: `make test-lua`; `luac -p`; `python3 scripts/download_car_wfs.py --help`.
- Manual: `tools/import_car.lua` sobre RO.json → `car.db`; spot-check
  `classify_point` em 2-3 coords (usar os focos RO recentes: ~74% devem cair em
  CAR).
- Done: lookup consulta `car.db`, classifica via célula+bbox+ray-cast e integra;
  reclassify via `nature_version`.

### Inc 7 — Frontend: natureza no mapa + painel (S, opcional)

**Depends on:** 5
**Unblocks:** none
**Done criteria:** foco colorido por `nature` no mapa e painel de estatísticas
consumindo `/api/fires/nature-stats`.

**Status:** DONE (2026-08-06) — `FIRE_NATURE_COLORS` + `fireStyle(fire)` com
fallback por confidence em `Home.js`; popup mostra "Natureza: …"; legenda no
mapa; `Dashboard/NatureStats.js` (classe + por estado) montado em `Dashboard.js`;
labels pt/en em `i18n.js`. `npm run build` verde.

#### Files to touch

##### frontend/src/components/Home.js
- What changes: `FIRE_NATURE_COLORS` (`crime`=vermelho, `suspeito`=laranja,
  `permitido`=verde, `natural`=azul/cinza) aplicado em `fireStyle`; popup mostra
  "Natureza: …"; chip de legenda.
- Integration points: campo `fire.nature` já vem do `/api/fires` (Inc 5).

##### frontend/src/components/Dashboard/NatureStats.js (NEW)
- What changes: busca `/api/fires/nature-stats?days=7`, lista por classe + por
  estado; montado em `Dashboard.js`.

##### frontend/src/i18n.js
- What changes: labels `nature.crime/suspeito/permitido/natural`.

#### Edge cases
- Foco sem `nature` (ainda não backfillado): fallback ao estilo por confidence
  atual, sem quebrar.

#### Verification
- Run: `cd frontend && npm run build`; `make test-lua` não aplicável.
- Manual: mapa mostra cores por natureza; painel reflete `/api/fires/nature-stats`.
- Done: natureza visível no frontend.

## Cross-cutting verification

- Após Inc 4: `journalctl -u yvy-backend` mostra passada de backfill sem
  `duration_ms` altos em outras rotas (prova de que não bloqueia o loop).
- Após Inc 5: `curl /api/fires/nature-stats?days=7` e `curl /api/fires` com
  `nature` preenchido no mesmo DB prod.
- Após Inc 6 (com dump do usuário): bump de `nature_version` + re-rodar Inc 4 e
  conferir que focos em imóveis CAR fora da moratória viram
  `permitido`/`suspeito` (não `crime`), e que focos antigos fora de CAR foram
  recomputados.
- CI: `make test-lua` + `luac -p` + `frontend-build` verdes a cada PR.
- Deploy do `car.db` (vários GB p/ 27 estados): NÃO commitar o arquivo no git —
  subir os GeoJSON `backend-lua/data/car/*.json` e rodar `tools/import_car.lua`
  no servidor (lsqlite3+cjson já presentes) OU copiar o `car.db` como artefato
  fora do git (ex: rsync/scp no passo de deploy). Definir no Ansible/runbook.

## Standards / common-mistakes referenced

- Sem `.agents/standards/` no workspace. Convenções do repo aplicadas:
  - JSONB BLOB: sempre `json(data)`/`json_extract` em SQL; nunca decodificar
    blob cru em Lua (AGENTS.md Gotchas).
  - Lua 5.1 (`lua5.1`/`luac5.1 -p`), SQLite ≥ 3.45 para `jsonb()`.
  - Loop copas single-threaded: trabalho CPU-bound vai para subprocesso
    (padrão `warm_ti_at_risk.lua`); nunca inline no loop.
  - Testes em busted (`make test-lua`), glob `tests/*.lua`, DB temporário com
    `env.set` + `package.loaded[...]=nil`.
  - Padrão de rota: `auth.enforce(ctx)` → `rl.enforce(ctx)` → cache Redis →
    compute → `redis.set` + `Cache-Control`.
  - SQLite otimizado (ver seção "Otimizações SQLite (aplicadas por tabela)"):
    RTree p/ espacial, JSONB p/ documentos, WAL + mmap p/ leitura pesada,
    `synchronous=OFF` p/ bulk load, VACUUM/ANALYZE pós-bulk.

## Open questions (CONSIDER from review)

- Adicionar `nature`/`nature_evidence`/`nature_at`/`nature_version` também à
  constante `SCHEMA` (CREATE TABLE) para instalações novas ficarem
  self-describing — incorporado no Inc 3 (ver spec).
- `count_fires_by_nature(days, state)` com filtro `acq_date >= ?` (mesma
  expressão de `find_fires_since`) e `COALESCE(state,'')` no agrupamento —
  incorporado no Inc 3.
- Semântica de sobreposição CAR: match por maior área / centroid mais próximo
  (tie-break em `evidence`) em vez de primeiro por índice — incorporado no Inc 6.
- Redis down → `setnx` retorna true → jobs duplicados possíveis; mitigado pela
  idempotência (`nature_version`); manter o guard mesmo no modo reclassify —
  aceito, igual ao ti-at-risk.
- Confirmar o nome real da coluna `fire_type` do FIRMS com amostra viva do CSV
  durante a verificação do Inc 1 (domínio numérico vs string) antes de confiar
  nos ramos térmicos — incorporado como passo do Inc 1.
- (desta revisão) Primeiro backfill → `nature-stats` mostra quase tudo
  `unclassified` até terminar; documentar ou servir `:stale` — aceito.
- (desta revisão) Deploy do `car.db`: artefato fora do git ou import no servidor
  — nota adicionada em cross-cutting.
- (desta revisão) `rtree` usa `id` 64-bit — ok p/ ~7M imóveis; não usar
  `rtree_i32`.

## Out of scope

- Integração com API pública do Sinaflor em tempo real (só hook plugável).
- Automação de coleta de decretos de moratória por ano (config revisada
  manualmente).
- (Resolvido) RTree: verificado disponível no SQLite 3.45.1 instalado — agora é
  o índice espacial principal do `car.db`; grade `car_cell` fica como fallback
  documentado para deploys sem o módulo.
- Frontend (Inc 7 opcional — confirmar com o usuário).
- Classificação de desmatamento PRODES (já é alerta separado `prodes`).
- (Resolvido) Aquisição do dump CAR: obtido via GeoServer oficial WFS
  (`scripts/download_car_wfs.py`) — 27 estados, sem captcha.
