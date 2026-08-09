# Otimizar Consultas de CAR e PRODES

> **Status: done** — All changes implemented, 236 tests pass (0 failures, 0 errors).

## Context

As consultas de PRODES e CAR/PRODES são os endpoints mais pesados do backend Lua.
Com 2M de pontos PRODES e 8.3M de imóveis CAR, os benchmarks locais revelam
gargalos concretos:

- **`ORDER BY rowid`** em `find_deforestation` e `get_deforestation_in_bbox`
  causa um TEMP B-TREE sort — **613ms → 30ms (20×) ao remover**.
- **`json(data)`** em runtime custa ~26ms por 10k rows; extração de campos
  individuais (`json_extract`) tem o mesmo custo mas evita decode Lua.
- **Schema flat**: `deforestation_data` guarda `year`/`class_type` apenas
  dentro do JSON `data.name` (ex: `"7 d2007"`). Toda consulta que precisa
  filtrar por ano/classe faz parse Lua do rótulo QML em runtime.
- **`/api/car/prodes`**: ray-cast Lua de até 50k pontos contra o polígono do
  imóvel, em cache miss Redis (cold path). A geometria já é decodificada
  uma vez (otimização existente), mas o loop de 50k iterações é CPU-bound
  no event loop copas.

O objetivo é reduzir latência dos endpoints PRODES e CAR/PRODES sem mudar
o formato das respostas da API.

## Assumptions and decisions

- **Decisão**: Remover `ORDER BY rowid` de `find_deforestation` e
  `get_deforestation_in_bbox`. Fonte: user-confirmed. O frontend não depende
  da ordem de rowid — os pontos são plotados num mapa Leaflet sem ordenação.
- **Decisão**: Adicionar colunas `year INTEGER` e `class_type TEXT` à tabela
  `deforestation_data`, extraídas do JSON `data.name` durante a ingestão.
  Fonte: user-confirmed. `year` é `INTEGER` (não `TEXT`) para preservar o
  tipo numérico da resposta atual (`tonumber(yyyy)`). `class_type` armazena
  a letra crua `"d"`/`"r"` (do `parse_prodes_label`); a rota traduz
  `d→deforestation / r→regrowth` (mesma lógica atual).
- **Decisão**: Otimizar ambos os endpoints — `/api/data` (mapa) e
  `/api/car/prodes` (ray-cast). Fonte: user-confirmed.
- **Assumption**: A migração de schema segue o padrão **additive inline em
  `init_db()`** (usado para `fire_data.nature` e `deter_alerts.municipality`).
  Não há `schema_migrations` table; `migrate.lua` é um script manual one-shot
  para JSONB migration, não roda no startup. Fonte: code @ `db.lua:310-345`.
- **Assumption**: O backfill de 2M rows não pode rodar no startup (bloqueia
  o backend por minutos). Solução: `ALTER TABLE` + índice no `init_db()`
  (rápido, idempotente), backfill via **script manual** (`scripts/deploy/`)
  rodado antes do deploy. As queries funcionam com NULLs enquanto o
  backfill não roda (fallback para `json(data)` + `parse_prodes_label`).
- **Assumption**: O `idx_def_bbox (lat, lon)` existente é suficiente para
  o filtro bbox. Fonte: code @ `db.lua:72-74` + benchmark (30ms sem ORDER BY).
- **Assumption**: O `CANDIDATE_LIMIT = 50000` em `car.lua` é suficiente.
  Fonte: code @ `car.lua:60`.
- **Assumption**: `idx_def_name` existente (`json_extract(data,'$.name')`)
  permanece — é usado por queries que buscam por nome exato. As novas
  colunas não o substituem; coexistem.

## Files to touch

### backend-lua/app/db.lua

- What changes: Adicionar colunas `year`/`class_type` ao schema; popular
  via backfill; modificar queries para usar colunas nativas com fallback.
- Function(s):
  - `SCHEMA` (line 53): adicionar colunas `year INTEGER`, `class_type TEXT`.
    (O `ALTER TABLE` real para DBs legados fica em `init_db()`.)
  - `init_db()` (line 270): adicionar bloco additive migration (mesmo
    padrão de `fire_data.nature`):
    1. `PRAGMA table_info(deforestation_data)` → checa se `year` existe.
    2. Se não: `ALTER TABLE deforestation_data ADD COLUMN year INTEGER`
       + `ALTER TABLE deforestation_data ADD COLUMN class_type TEXT`.
    3. `CREATE INDEX IF NOT EXISTS idx_def_year ON deforestation_data(year)`
       (índice simples, não composto — `class_type` não é filtrada sozinha.)
  - `_M.bulk_upsert_deforestation(docs)` (line 1374): extrair `year`/
    `class_type` de `data.name` via `parse_prodes_label` antes do INSERT,
    e incluir como colunas na query `INSERT INTO deforestation_data
    (lat, lon, data, year, class_type) VALUES (...)`.
  - `_M.find_deforestation(sw_lat, ne_lat, sw_lng, ne_lng, limit)` (line 1403):
    **remover `ORDER BY rowid`** (única mudança — 20× speedup medido).
    Manter `json(data)` + decode Lua (a reescrita para `json_extract`
    não tem benefício medido e adiciona 6× function evals por row).
  - `_M.get_deforestation_in_bbox(sw_lat, ne_lat, sw_lng, ne_lng, limit)` (line 1455):
    **remover `ORDER BY rowid`**. Substituir o bloco Lua de parse por
    leitura direta das colunas `year`/`class_type` com **fallback**:
    ```lua
    SELECT lat, lon, year, class_type, json_extract(data, '$.name') AS name
    FROM deforestation_data
    WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
    LIMIT ?
    ```
    No Lua, montar o resultado:
    ```lua
    for _, r in ipairs(rows) do
        local year, class_type = r.year, r.class_type
        local class_name = r.name  -- rótulo QML completo ("7 d2007")
        -- Fallback: se year/class_type ainda NULL (backfill não rodou),
        -- usa parse_prodes_label no name (comportamento atual)
        if not year and class_name then
            local t, yyyy = parse_prodes_label(class_name)
            if t then year = tonumber(yyyy); class_type = t end
        end
        local kind = class_type and ((class_type == "d") and "deforestation" or "regrowth") or nil
        result[#result + 1] = {
            lat = r.lat, lon = r.lon,
            class_name = class_name,
            year = year,      -- INTEGER (preserva tipo numérico da resposta)
            type = kind,
        }
    end
    ```
- Data shapes:
  - `deforestation_data` row: `(id, lat, lon, data BLOB, year INTEGER, class_type TEXT)`
  - `find_deforestation` retorna: `[{name, lat, lon, color, clazz, periods, source, timestamp}]` (inalterado)
  - `get_deforestation_in_bbox` retorna: `[{lat, lon, class_name, year, type}]` (inalterado — `year` é número, `type` é `"deforestation"|"regrowth"`)
- Integration points:
  - `routes/deforestation.lua` chama `find_deforestation` — não muda.
  - `routes/car.lua` chama `get_deforestation_in_bbox` — não muda
    (`p.class_name`, `p.year`, `p.type` continuam presentes).
  - `ingest.lua` chama `bulk_upsert_deforestation` — recebe os docs e
    passa para db.lua; a extração acontece dentro de `bulk_upsert`.
- Error paths:
  - **Linhas com `year`/`class_type` NULL (backfill não rodou)**: fallback
    para `parse_prodes_label(class_name)` — exatamente o comportamento
    atual. Nenhuma regressão.
  - Se `parse_prodes_label` falhar no INSERT: `year`/`class_type` ficam
    NULL — mesmo comportamento atual em runtime.

### scripts/deploy/backfill_prodes_columns.lua (NOVO)

- What changes: Script manual one-shot que faz o backfill das colunas
  `year`/`class_type` em batches. Rodado **antes do deploy**, não no startup.
- Function(s):
  - `backfill()`:
    1. Abrir `yvy.db` diretamente (não via pool — é uma operação offline).
    2. Loop: `SELECT id, json_extract(data, '$.name') FROM deforestation_data
       WHERE year IS NULL ORDER BY rowid LIMIT 10000`
    3. Para cada row: `parse_prodes_label(name)` em Lua → extrair
       `year` (INTEGER) e `class_type` (TEXT `"d"`/`"r"`).
    4. `UPDATE deforestation_data SET year=?, class_type=? WHERE id=?`
       dentro de uma transação por batch.
    5. Logar progresso: `"Backfilled batch N: 10000 rows (total: M)"`.
    6. Repetir até `SELECT COUNT(*) FROM deforestation_data WHERE year IS NULL = 0`.
- Data shapes: N/A (UPDATE only)
- Integration points: Rodar manualmente: `lua scripts/deploy/backfill_prodes_columns.lua`
  ou `make backfill-prodes` (novo target no Makefile).
- Error paths:
  - Se o script for interrompido, retoma de onde parou (`WHERE year IS NULL`).
  - Se `parse_prodes_label` falhar para uma row: `year`/`class_type`
    permanecem NULL para essa row (não bloqueia o batch).
  - **O backfill usa `parse_prodes_label` em Lua** (não `json_extract`)
    porque o padrão `([dr])(%d%d%d%d)` casa em qualquer posição do label
    e SQLite não tem regex nativo.

### backend-lua/app/routes/car.lua

- What changes: O loop de ray-cast em `get_prodes_status` não muda
  significativamente — a otimização principal vem de `get_deforestation_in_bbox`
  (remoção do `ORDER BY` + colunas nativas). Apenas adicionar observabilidade.
- Function(s):
  - `_M.get_prodes_status(ctx)` (line 75):
    - Adicionar `if #points > 10000 then logger.warn("car/prodes slow path: "
      .. #points .. " candidates for " .. cod) end` para imóveis grandes.
    - O early-exit `#points == 0` já é implícito (loop vazio → `has_prodes=false`),
      mas pode ser explícito para clareza.
- Data shapes: Resposta inalterada.
- Integration points: `db.get_deforestation_in_bbox` agora retorna
  `year`/`class_type` direto (ou fallback) — `p.class_name`, `p.year`,
  `p.type` continuam presentes, então o loop de agregação em `car.lua:120-155`
  não muda.
- Error paths: N/A.

### backend-lua/app/ingest.lua

- What changes: Passar `year`/`class_type` extraídos junto com cada doc
  para `bulk_upsert_deforestation`, ou deixar a extração dentro do
  `bulk_upsert` (preferido — menos mudança em ingest.lua).
- Function(s): Nenhuma mudança de assinatura. Se a extração ficar em
  `bulk_upsert_deforestation`, `ingest.lua` não muda.
- Integration points: `ingest_prodes` chama `bulk_upsert_deforestation`.
- Error paths: N/A.

## Edge cases

- **Backfill em DB de 2M rows**: O backfill via script manual roda antes do
  deploy (não no startup). O backend serve normalmente com NULLs — as
  queries têm fallback para `parse_prodes_label`. Estimativa: ~5-10 min
  para 2M rows em batches de 10k.
- **Re-ingest com PRODES_FORCE_UPDATE**: Após truncate + re-ingest, as
  novas linhas já terão `year`/`class_type` preenchidos no INSERT.
- **Imóvel sem PRODES**: O loop vazio já retorna `has_prodes = false`
  naturalmente — nenhuma otimização especial necessária.
- **Linhas com `data.name` que não casa `parse_prodes_label`**: `year`
  e `class_type` ficam NULL — mesmo comportamento atual (`type=nil`,
  `class_name` = label bruto).
- **DB legado sem as colunas**: `init_db()` faz `ALTER TABLE` idempotente
  (via `PRAGMA table_info` check). As queries usam `SELECT year, class_type`
  que funcionam imediatamente após o `ALTER` (retornam NULL até o backfill).
- **SQLite `UPDATE ... LIMIT`**: Confirmar versão do SQLite. Se <3.35
  (sem suporte a `UPDATE...LIMIT`), usar `UPDATE ... WHERE id IN (SELECT
  id FROM ... WHERE year IS NULL LIMIT 10000 ORDER BY rowid)` — subquery
  com `ORDER BY rowid` garante resumabilidade determinística.
- **Índice `idx_def_name` existente**: Permanece inalterado — as novas
  colunas não o substituem. Coexistem sem conflito.

## Verification

- Run: `cd backend-lua && busted --verbose tests/*.lua`
- Tests to add/update:
  - `test_car_prodes.lua`: verificar que `get_deforestation_in_bbox` retorna
    `year` como número (INTEGER), `type` como `"deforestation"|"regrowth"`,
    e `class_name` como label bruto — tanto do path das novas colunas
    quanto do fallback (rows com year NULL).
  - `test_ingest.lua`: verificar que `bulk_upsert_deforestation` preenche
    `year`/`class_type` corretamente a partir de `data.name` (ex: `"7 d2007"`
    → year=2007, class_type="d").
  - `test_deforestation_stats.lua`: garantir que `find_deforestation`
    retorna os mesmos resultados (conteúdo) após remover `ORDER BY rowid`.
  - Novo teste de `init_db`: verificar que `ALTER TABLE` é idempotente
    (rodar 2× sem erro — colunas já existem).
- Manual:
  1. Iniciar backend: `make stop && make start` (ALTER TABLE roda em init_db).
  2. Verificar colunas: `python3 -c "import sqlite3; db=sqlite3.connect('backend-lua/data/yvy.db'); print([r for r in db.execute('PRAGMA table_info(deforestation_data)').fetchall()])"`
  3. Rodar backfill: `lua scripts/deploy/backfill_prodes_columns.lua`
  4. Verificar backfill: `python3 -c "import sqlite3; db=sqlite3.connect('backend-lua/data/yvy.db'); print(db.execute('SELECT COUNT(*) FROM deforestation_data WHERE year IS NULL').fetchone())"`
  5. `make stop && make start`
  6. Abrir `http://localhost:5001` e verificar mapa PRODES
  7. Testar `/api/car/prodes?cod_imovel=<cod>` em cache miss (flush Redis)
  8. Comparar latência antes/depois com `curl -w '%{time_total}'`
- Done criteria: `/api/data` em bbox 5°×6° < 50ms (era 613ms);
  `/api/car/prodes` cache miss < 200ms para imóvel típico.

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` §3 — Batch-write/read pipelines
  need the same batching pattern as siblings (N+1 is a code smell). Aplica:
  a extração de year/class_type deve ser batch no INSERT, não per-row em
  runtime.
- `.agents/common-mistakes/common-mistakes.md` §5 — Destructive update paths
  need marker-after-success + auto-restore. Aplica: a migration de schema
  deve ser idempotente e o backfill deve ser resumível.
- `.agents/common-mistakes/common-mistakes.md` §1 — Test fixtures must be
  clock-relative, never absolute dates. Aplica: testes de migration não
  devem depender de datas fixas nos dados de PRODES.

## Estimated scope
M

## Open questions (CONSIDER from review)

- **`idx_def_name` existente** (`json_extract(data,'$.name')`): As novas
  colunas `year`/`class_type` coexistem com ele. Verificar se `idx_def_name`
  ainda é usado por alguma query (ex: busca por nome exato) e documentar
  a decisão de mantê-lo. Provavelmente sim — é usado por queries que
  filtram por `data.name` que não casam `parse_prodes_label`.
- **`UPDATE ... LIMIT` + `ORDER BY rowid` para resumabilidade**: Confirmar
  versão do SQLite em produção. Se <3.35, usar subquery
  `WHERE id IN (SELECT id FROM ... LIMIT 10000 ORDER BY rowid)` para
  resumabilidade determinística no backfill.