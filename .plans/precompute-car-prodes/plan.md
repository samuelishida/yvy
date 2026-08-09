# Pré-calcular CAR × PRODES no car.db

> Otimização do endpoint `/api/car/prodes` (clique no mapa → cruzar CAR com PRODES).
>
> **STATUS: IMPLEMENTADO (2026-08-09).** Todos os componentes criados; testes
> `tests/test_car_prodes_precompute.lua` (7) + `tests/test_car_prodes_warm.lua`
> (5) + `tests/test_car_prodes.lua` (11) passando (248 no total); smoke test
> live confirmou `precomputed=true` na rota. Fluxo de produção:
> `make warm-car-prodes` (sequential) ou `clone_car_prodes_worker.sh`
> (paralelo por UF + merge). Ver RUNBOOK "Pré-cálculo CAR × PRODES".
>
> **Incrementos extras do implement-plan (2026-08-09):**
> - `warm_car_prodes.lua` agora faz `backup_if_needed` do car.db antes da 1ª
>   escrita (DB principal; clones são descartáveis) e é require-ável para testes
>   (padrão `deter_protected_alerts.lua`), com `_M._skip_redis_invalidation`.
> - `merge_car_prodes.lua` garante o schema `car_prodes` no target (car.db
>   legado não quebra o merge) e é require-ável, exportando `_M.merge(target, clones)`.
> - `tests/test_car_prodes_warm.lua` (NOVO, 6 testes): warm cria só rows
>   positivas, não grava negativas, version_key correto, merge de 2 clones,
>   merge rejeita version_key divergente, merge de >10 clones (batching) +
>   substituição de rows antigas do target.
>
> **Execução local (2026-08-09, warm completo 27 UFs × 15 workers):**
> - `tools/clone_car_uf.lua` (NOVO): clone FILTRADO por UF via ATTACH+INSERT
>   SELECT (preserva o storage class BLOB do geom — copiar BLOB por Lua liga como
>   TEXT e corrompe o JSONB → "malformed JSON"). Sem CLI sqlite3. ~car.db/27.
> - `clone_car_prodes_worker.sh` reescrito: usa clone_car_uf.lua, compartilha o
>   yvy.db read-only (warm só lê PRODES), 15 workers.
> - **Lições do merge:** (1) SQLite limita ATTACH a 10 → merge em lotes de 8
>   (valida version_key abrindo cada clone individualmente). (2) DETACH falha
>   dentro de transação ("database is locked") → sem transação global (merge é
>   offline idempotente). (3) target com version_key antigo (warm anterior /
>   smoke test) → DELETE rows não-dominantes + INSERT OR REPLACE (substituição,
>   não aborto).
> - Resultado local: car_prodes = **645.468 rows**, 1 version_key
>   (`c2ad25e0c2ad25e0`). Top UFs: PA 137.717, MT 96.632, MA 68.205, MG 52.047,
>   BA 39.567. RO ausente no car.db local (dado não importado) → clone vazio,
>   tolerado pelo merge. car.db cresceu de 6,9 GB → 7,1 GB.
> - Deploy: snapshot consistente via `VACUUM INTO` → upload para
>   `/opt/yvy/backend-lua/data/car/car.db` no prod (swap com backend parado,
>   backup `car.db.bak-preprodes-*` mantido no prod). **DONE 2026-08-09**:
>   backend prod ativo/healthy, 645.468 rows com version_key `c2ad25e0`,
>   `/api/car/prodes` responde. **Nota:** prod ainda tem o código ANTIGO (sem
>   car_prodes.lua) — a tabela fica pronta mas a rota só passa a lê-la após o
>   deploy do backend. version_key bate (COUNT PRODES idêntico 2.001.410 entre
>   local e prod).
> - SCP 7 GB: `scp` travou em 3,6 GB (rede instável) → `rsync --partial
>   --append-verify` retomou do ponto parado (speedup 2×). Preferir rsync para
>   arquivos grandes.

## Context

O endpoint `/api/car/prodes` hoje resolve o imóvel pelo `cod_imovel`, faz scan de PRODES no bbox do imóvel + padding, e executa ray-cast Lua ponto-a-ponto contra o polígono do imóvel (até 50k candidatos). Esse caminho cold é CPU-bound no event loop copas e lento para imóveis grandes.

O projeto já tem um padrão de pré-cálculo offline para CAR × UC/TI (`car_protected_overlap` no `car.db`, `warm_car_protected_overlap.lua`, `merge_car_protected_overlap.lua`). O objetivo é aplicar o mesmo padrão a CAR × PRODES, gerando offline uma tabela `car_prodes` no `car.db` com o resultado da verificação por imóvel, de forma que a rota sirva quase instantaneamente no clique.

A operação offline deve ser paralelizável por UF e mergeável via SCP — workers independentes processam UFs em clones do `car.db`/`yvy.db` e depois o merge gera o `car.db` final a subir para produção.

## Assumptions and decisions

- **Decisão**: Criar tabela `car_prodes` no `car.db` com PK `cod_imovel`, guardando o resultado completo da rota (`cod_imovel`, `found`, `has_prodes`, `prodes_area_ha`, `property_area_ha`, `pct_deforested`, `years`, `classes`, `regrowth`, `sampled`, `bbox`, `area_estimate`, `version_key`, `computed_at`). Fonte: user-confirmed + MUST-FIX review (#2).
- **Decisão**: `version_key` composto por sinais estáveis e baratos do PRODES + config. Fonte: user-confirmed + MUST-FIX review (#1, #2 revisão). Usa: `COUNT(*), MIN(year), MAX(year) FROM deforestation_data` + uma hash das **coordenadas dos pontos PRODES amostradas** (ex: SHA-3 ou DJB2a de uma amostra determinística de até 10k pontos ordenados por lat/lon, suficiente para detectar reclassificação ou movimentação de pontos sem full scan) + `PRODES_VERSION` (env) se disponível; e os parâmetros de cálculo (`PAD_DEG`, `PIXEL_HA`, `CANDIDATE_LIMIT`). NÃO inclui `SUM(lat)/SUM(lon)` (instável) nem bounds globais do CAR (causa rewarm desnecessário em toda importação de UF). Fonte: review.
- **Decisão**: Pré-cálculo offline por UF, paralelizável (`xargs -P` ou timers) + merge dos clones via SCP. Fonte: user-confirmed.
- **Decisão**: Antes de clonar, o operador deve parar o backend e fazer `PRAGMA wal_checkpoint(TRUNCATE)` (ou usar `.backup`/`.clone` do SQLite) para garantir `car.db` e `yvy.db` consistentes. Fonte: MUST-FIX review (#3 revisão).
- **Decisão**: **Não fazer auto-repair da rota runtime no `car.db`**. Fonte: user-confirmed + MUST-FIX review (#3). O `car.db` é aberto pelo backend com `PRAGMA query_only=ON` e a runtime não deve escrevê-lo. O fallback live continua existindo e ainda grava no Redis (24h) como hoje. O `car_prodes` é populado offline. Se um imóvel não estiver no `car_prodes`, a rota computa live e guarda no Redis; a próxima warm offline o captura.
- **Decisão**: Armazenar **apenas imóveis com `area_ha >= CAR_PRODES_MIN_AREA_HA`**; imóveis menores são sempre computados on-the-fly. Fonte: SHOULD-FIX review (#7). Valor default 10 ha (≥ 1 pixel PRODES aproximado + margem), enviável via `CAR_PRODES_MIN_AREA_HA`. Documentar em `.env.example` e RUNBOOK.
- **Assumption**: O `car.db` é um cold cache; a runtime só lê a tabela `car_prodes`. Fonte: code @ `car_lookup.lua:218-220` (`PRAGMA query_only=ON`). A tabela deve ser escrita por processos offline, nunca pelo backend runtime.
- **Assumption**: Resultado armazenado espelha a resposta atual da rota; o frontend (`Home.js:936`) consome `data.has_prodes`, `data.prodes_area_ha`, `data.years`, `data.classes`, `data.regrowth`. Fonte: code @ `Home.js:930-940`.
- **Assumption**: A área de PRODES é pixel-based (0.09 ha/pixel) e `sampled` indica truncamento por `CANDIDATE_LIMIT`. Ambos derivam diretamente dos dados atuais, então podem ser pré-calculados. Fonte: code @ `car.lua:50-60`.
- **Assumption**: **Não armazenar registros negativos** (`has_prodes=false`) no `car_prodes`. Fonte: SHOULD-FIX review (#6, #12). Imóveis sem PRODES são baratos de detectar on-the-fly via scan vazio + Redis cache; economiza espaço (evita ~1 GB de negativas) e mantém a tabela pequena. A warm gera apenas rows positivas.
- **Assumption**: Invalidação por mudança de CAR é feita por **UF delete** dentro do import, não por version_key global do CAR. Fonte: MUST-FIX review (#4).
- **Assumption**: Os workers de warm usam clones independentes do `car.db` e do `yvy.db` para evitar contenção. Fonte: MUST-FIX review (#5).

## Files to touch

### backend-lua/app/car_import.lua
- What changes: Adicionar schema `CREATE TABLE IF NOT EXISTS car_prodes (...)` e função `create_car_prodes_schema(conn)` análoga a `create_car_protected_schema`. Invalidar pré-cálculo da UF durante o reimport.
- Function(s):
  - `_M.create_car_prodes_schema(conn)` (nova):
    ```sql
    CREATE TABLE IF NOT EXISTS car_prodes (
      cod_imovel TEXT PRIMARY KEY,
      found INTEGER NOT NULL DEFAULT 1,
      has_prodes INTEGER NOT NULL DEFAULT 0,
      prodes_area_ha REAL NOT NULL DEFAULT 0,
      property_area_ha REAL NOT NULL DEFAULT 0,
      pct_deforested REAL NOT NULL DEFAULT 0,
      years TEXT NOT NULL DEFAULT '[]',
      classes TEXT NOT NULL DEFAULT '[]',
      regrowth INTEGER NOT NULL DEFAULT 0,
      sampled INTEGER NOT NULL DEFAULT 0,
      bbox TEXT NOT NULL,
      area_estimate TEXT NOT NULL DEFAULT 'pixel-based',
      version_key TEXT NOT NULL,
      computed_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_car_prodes_computed_at ON car_prodes(computed_at);
    CREATE INDEX IF NOT EXISTS idx_car_prodes_version_key ON car_prodes(version_key);
    ```
  - `_M.delete_car_prodes_for_uf(conn, uf)` (nova): `DELETE FROM car_prodes WHERE cod_imovel IN (SELECT cod_imovel FROM car_data WHERE uf = ?)`.
- Data shapes: `years` e `classes` como JSON TEXT (colunas do car.db usam TEXT para arrays, igual `car_protected_overlap.overlaps`).
- Integration points: Chamada em `import_car.lua` e no warm offline.
- Error paths: Schema idempotente via `CREATE TABLE IF NOT EXISTS`.

### backend-lua/app/lookups/car_prodes.lua (NOVO)
- What changes: Módulo separado de lookup + writer para `car_prodes`, espelhando `car_protected_overlap.lua`.
- Function(s):
  - `_M.db_path()` — reusa `car_lookup.db_path()`.
  - `_M.ensure_schema(conn)` — chama `car_import.create_car_prodes_schema`. Se `conn` estiver em modo read-only (`query_only=ON` ou disco read-only), detecta e retorna graciosamente sem falhar; a rota cai para live computation.
  - `_M.current_version_key()` — hash determinístico composto por:
    - PRODES: `SELECT COUNT(*), MIN(year), MAX(year) FROM deforestation_data` + hash determinístico de uma amostra ordenada dos pontos PRODES (ex: 10k primeiros por lat/lon) + `env.get("PRODES_VERSION", "")`.
    - Config: `PAD_DEG`, `PIXEL_HA`, `CANDIDATE_LIMIT`.
    - NÃO inclui bounds globais do CAR.
  - `_M.get(cod_imovel)` — lê registro decodificado ou nil. Retorna `nil` também se `version_key` diferir do atual. Proteção por `pcall` no decode.
  - `_M.bulk_upsert(rows)` — upsert em batch em chunks de 500 (mesmo padrão de `warm_car_protected_overlap.lua`).
  - (sem `_M.upsert` de runtime; auto-repair foi removido por decisão).
- Data shapes: Entrada `result` é a tabela montada em `car_routes.get_prodes_status`.
- Integration points: `routes/car.lua:get_prodes_status` chama `_M.get` no início (antes do scan PRODES). `car_import.lua` chama schema creation.
- Error paths: Proteção por `pcall` no decode JSON; registro corrompido tratado como miss.

### backend-lua/app/routes/car.lua
- What changes: `get_prodes_status` consulta `car_prodes` logo após o Redis miss; se houver registro válido (mesmo `version_key`), retorna imediatamente; senão cai no caminho live atual. Sem auto-repair no `car.db`.
- Function(s):
  - `_M.get_prodes_status(ctx)`:
    1. Cache Redis (mantido, igual hoje).
    2. Se miss, carrega `car_prodes` e verifica `version_key`.
    3. Se fresh e encontrado: `ctx:json(200, { ok=true, cached=false, data=rehydrated })`.
    4. Se ausente/stale: executa caminho live (scan PRODES + ray-cast), guarda no Redis e retorna.
- Data shapes: A resposta da API permanece inalterada. Rehydration preenche todos os campos da rota, incluindo `property_area_ha`.
- Integration points: `car_prodes.get`, `car_lookup`, `db.get_deforestation_in_bbox`.
- Error paths: Registro corrompido ou `version_key` stale → miss; live computation continua funcionando.

### backend-lua/tools/warm_car_prodes.lua (NOVO)
- What changes: Script offline que pré-calcula CAR × PRODES por UF, gerando apenas rows positivas na tabela `car_prodes` no `car.db` (ou clone alternativo).
- Function(s):
  - `candidate_ids(conn, uf_filter)` — imóveis com `area >= CAR_PRODES_MIN_AREA_HA` e `geom IS NOT NULL`, opcionalmente filtrados por UF. Para a primeira versão não faz filtro por interseção com PRODES; assume-se que o operador invoca por UF e a quantidade de positivos é pequena. O scan de todos os candidatos é aceitável offline.
  - `process_imovel(prop, version_key)` — chama `db.get_deforestation_in_bbox` com bbox do imóvel + padding e executa o mesmo loop de agregação de `routes/car.lua`. Retorna row pronta para upsert **apenas se `has_prodes=true`**.
  - `run_batch(uf_filter, alt_db_path)` — similar a `warm_car_protected_overlap.lua:run_batch`. Faz backup do clone antes de escrever `car_prodes` (reusa padrão `create_backup`/`restore_backup` existente).
- Data shapes: Buffer de rows para `bulk_upsert` em chunks de 500.
- Integration points: `car_lookup.load_car`, `db.init_db`, `car_prodes.bulk_upsert`.
- Error paths: Proteção por `pcall` em cada imóvel; falha de um não aborta o batch.

### backend-lua/tools/import_car.lua
- What changes: Adicionar chamada a `car_import.delete_car_prodes_for_uf(conn, uf)` **dentro da transação de import por UF**, análogo ao `delete_car_protected_for_uf` existente. Garantir que a UF seja conhecida no loop de import.
- Function(s):
  - No loop por UF, antes de `DELETE FROM car_data WHERE uf = '...'`, executar `car_import.delete_car_prodes_for_uf(conn, uf)`.
- Integration points: `car_import.lua` já chama `create_schema` e `create_car_protected_schema`; adiciona `create_car_prodes_schema(conn)`.
- Error paths: Falha na deleção aborta a transação (ROLLBACK) e o import da UF.

### backend-lua/tools/clone_car_prodes_worker.sh (NOVO)
- What changes: Script de preparação de clones para paralelização por UF. Cria diretório temporário, copia `car.db` e `yvy.db` base, invoca `warm_car_prodes.lua` com `alt_db_path`, e retorna o clone pronto para merge.
- Function(s):
  - Recebe `UF` e `OUTPUT_DIR`.
  - Copia `backend-lua/data/car/car.db` → `$OUTPUT_DIR/car_$UF.db` (recomendado usar `sqlite3 .backup` ou copiar após parar backend + wal_checkpoint).
  - Copia `backend-lua/data/yvy.db` → `$OUTPUT_DIR/yvy_$UF.db`.
  - Seta `CAR_DB_PATH` e `SQLITE_PATH` para os clones e roda `lua5.1 tools/warm_car_prodes.lua $UF $OUTPUT_DIR/car_$UF.db`.
- Integration points: Chamado por `xargs -P` ou por um orquestrador.
- Error paths: Se a cópia ou warm falhar, loga e sai com código != 0.

### backend-lua/tools/merge_car_prodes.lua (NOVO)
- What changes: Merge de clones por UF para o `car.db` final, análogo a `merge_car_protected_overlap.lua`.
- Function(s):
  - Antes do merge, valida que todos os clones têm a **mesma** `version_key` na tabela `car_prodes` (aborta se divergir).
  - ATTACH clones + `INSERT OR REPLACE INTO car_prodes SELECT ... FROM c<i>.car_prodes`.
  - `VACUUM` no final.
- Integration points: Chamado após gerar clones por UF.
- Error paths: Se um clone não tiver tabela ou `version_key` divergir, loga e aborta.

### backend-lua/Makefile
- What changes: Adicionar targets `warm-car-prodes` e `merge-car-prodes`, e documentar o fluxo paralelo.
- Function(s):
  - `warm-car-prodes: $(TARGET)` → roda `tools/warm_car_prodes.lua` (modo single-UF ou todas, sequencial).
  - `warm-car-prodes-parallel: $(TARGET)` → exemplo com `xargs -P` usando `clone_car_prodes_worker.sh`.
  - `merge-car-prodes: $(TARGET)` → roda `tools/merge_car_prodes.lua`.
- Data shapes: N/A.

### backend-lua/tests/test_car_prodes.lua
- What changes: Adicionar testes para o caminho de pré-cálculo.
- Tests to add:
  - Registro fresh é servido sem scan PRODES (verificar que a resposta vem de `car_prodes.get`).
  - Registro stale (version_key antigo) cai para live computation.
  - Registro ausente → live computation.
  - `car_prodes.current_version_key()` muda após alterar `deforestation_data` ou `PRODES_VERSION`.
  - Formato da resposta inalterado (inclui `property_area_ha`).

### backend-lua/tests/test_car_prodes_warm.lua (NOVO) — ✅ DONE
- What changes: Testa o warm offline e o merge.
- Tests:
  - `warm_car_prodes.lua` processa imóveis da fixture e cria registros positivos em `car_prodes`. ✅
  - Não cria registro para imóvel sem PRODES (sem negativas). ✅
  - `merge_car_prodes.lua` mergeia dois clones corretamente. ✅ (+ rejeita version_key divergente)

## Edge cases

- **PRODES muda após warm**: `current_version_key()` muda e todos os registros existentes ficam stale; a rota recomputa live até a próxima warm offline.
- **CAR muda (import de UF)**: `import_car.lua` deleta `car_prodes` da UF dentro da transação de import, forçando warm da UF.
- **Registro corrompido no car.db**: `car_prodes.get` usa `pcall` no decode; retorna nil → live computation.
- **Imóvel abaixo de `CAR_PRODES_MIN_AREA_HA`**: ignorado no warm; rota live continua funcionando.
- **Merge de clones com version_key diferente**: o merge aborta se `version_key` divergir entre clones; todos os workers devem usar o mesmo estado de PRODES/config.
- **Backend prod lê DB sem `car_prodes`**: schema é criado no `import_car.lua` (offline). Se faltar, `car_prodes.ensure_schema` detecta read-only e a rota usa live computation sem tentar escrever.
- **SCP**: operador manual. O plano não inclui automação de deploy, apenas instrução de copiar o `car.db` final gerado pelo merge.
- **Warm cancelado a meio caminho**: clones são descartáveis; merge só acontece após todos os workers terminarem com sucesso.

## Verification

- Run: `cd backend-lua && busted --verbose tests/*.lua`
- Manual:
  1. `make backfill-prodes` (se ainda houver NULLs).
  2. Preparar clones e rodar warm paralelo: exemplo a documentar no Makefile.
  3. `make merge-car-prodes`.
  4. Verificar tabela: `sqlite3 backend-lua/data/car/car.db "SELECT COUNT(*) FROM car_prodes"`.
  5. Iniciar backend, clicar em imóvel no mapa, medir latência de `/api/car/prodes`.
  6. Flush Redis e repetir para testar cold path com `car_prodes`.
- Done criteria: `/api/car/prodes` em imóvel típico retorna em < 50ms no cache miss (com pré-cálculo fresh), com testes passando e sem auto-repair no `car.db`.

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` §3 — batch-write/read pipelines precisam do mesmo padrão de batching dos siblings. Aplica: o warm deve usar `bulk_upsert` em chunks de 500 (mesmo padrão de `warm_car_protected_overlap.lua`).
- `.agents/common-mistakes/common-mistakes.md` §5 — destructive update paths precisam de marker-after-success + auto-restore. Aplica: `import_car.lua` deve deletar pré-cálculo da UF dentro da transação de reimport; nunca truncar toda a tabela `car_prodes`.
- `.agents/common-mistakes/common-mistakes.md` §2 — testes não devem escrever em namespaces Redis de produção. Aplica: testes de warm invalidam apenas chaves de fixture.

## Estimated scope
M

## Open questions (CONSIDER from review)

- **Adicionar `PRODES_OVERLAP_STALE_DAYS`?** PRODES é anual; talvez não seja necessário, mas um teto de 365 dias pode evitar rows pré-calculadas ficarem servidas para sempre se `current_version_key()` não mudar.
- **Extrair base genérica `car_precomputed.lua`** para `car_protected_overlap` e `car_prodes` compartilharem `ensure_conn`, `short_hash`, `bulk_upsert`, etc. Aumenta reúso mas adiciona scope; avaliar se vale a pena neste PR.
- **Filtro de candidatos por interseção com bbox dos dados PRODES:** pode reduzir o número de imóveis processados no warm, mas exige uma query de extensão espacial da `deforestation_data`. Manter para iteração futura se o warm por UF ficar lento.
- **Indexação adicional:** já incluímos `idx_car_prodes_version_key`; avaliar se `idx_car_prodes_computed_at` ainda é necessário.
