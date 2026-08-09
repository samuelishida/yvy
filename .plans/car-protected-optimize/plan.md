# Pré-cálculo offline do overlap CAR × UC/TI

## Context

`/api/car/protected` ([backend-lua/app/routes/car.lua:250-318](backend-lua/app/routes/car.lua#L250-L318)) responde "qual a fração do imóvel CAR que cai dentro de UC/TI?". Hoje o cálculo é **on-the-fly, toda request**: Monte-Carlo grid sampling (default 32² = 1024 pontos, adaptativo até 128² = 16384) sobre o bbox do imóvel, ray-cast contra TODOS os candidatos UC/TI cujo bbox sobrepõe o imóvel ([lookups/conservation_units_lookup.lua:140-150](backend-lua/app/lookups/conservation_units_lookup.lua#L140-L150), [lookups/indigenous_lands_lookup.lua:120-130](backend-lua/app/lookups/indigenous_lands_lookup.lua#L120-L130)). Resultado cacheado em Redis `car:protected:<COD>` por **24h** ([routes/car.lua:175](backend-lua/app/routes/car.lua#L175), [routes/car.lua:261](backend-lua/app/routes/car.lua#L261)).

Em prod, a query fica "meio lenta" porque:

1. **Cold path**: imóvel nunca visto → 1024 ray-casts × todos os candidatos UC/TI (298 UC + 547 TI segundo `tools/deter_protected_alerts.lua:6`). Imóveis rurais pequenos no MATOPIBA têm dezenas de TIs candidatas.
2. **Adaptive sampling dobra várias vezes** ([routes/car.lua:303-307](backend-lua/app/routes/car.lua#L303-L307)): se `max_pct` cai na faixa de ±5% do threshold 80%, vai 32→64→128 (4× o trabalho). Pior para imóveis na fronteira TI×UC.
3. **TTL 24h + sem stamp de versão**: se a fonte UC/TI mudar (download de `conservation_units.json` / `indigenous_lands.json`), o cache serve dados potencialmente errados por até 24h.
4. **CAR é estático** (importado offline via `tools/import_car.lua`); **UC/TI mudam raramente** (mesma origem JSON); **portanto o resultado também é quase estático**.

**Decisão do usuário (confirmada):** pré-cálculo batch offline (resolve cold-path de uma vez para o estoque inteiro do `car.db`) + TTL Redis **mantido em 86400s (24h)** (override da recomendação inicial de 1h, porque UC/TI raramente mudam e o operador re-executa o batch quando necessário).

## Assumptions and decisions

- **Decision:** armazenar resultados do pré-cálculo em uma **nova tabela `car_protected_overlap`** dentro do `car.db` existente (não no `yvy.db`). Source: code @ `backend-lua/app/lookups/car_lookup.lua:21` — `car.db` é o cold cache do CAR, e `car_protected` é uma derivação determinística dele. Mantém tudo do CAR coeso e reusa o mesmo import path.
- **Decision:** script batch `backend-lua/tools/warm_car_protected_overlap.lua`, modelado em `tools/deter_protected_alerts.lua` (carrega UC/TI lookups → varre `car_data` → grava). Source: code @ `tools/deter_protected_alerts.lua:1-25`. Detached process (não inline no request loop), como o resto dos warms.
- **Decision:** pré-cálculo roda com `OVERLAP_SAMPLES=64` (compromisso: precisão + velocidade). Adaptive sampling **desligado** no batch (não precisa, é determinístico; rodamos a grade fixa e salvamos o resultado final). Source: code @ `routes/car.lua:177-181`.
- **Decision:** schema armazena apenas `overlaps` (lista já computada), `status` (`ok`/`suspeito`/`indeterminado`), `sampled`, `max_pct`, `threshold`, `computed_at` — espelha o payload atual de `get_protected_overlap` ([routes/car.lua:307-313](backend-lua/app/routes/car.lua#L307-L313)).
- **Decision:** rota runtime fica **fallback**: ler do `car_protected_overlap` (cache permanente); se faltar ou `computed_at` mais antigo que X dias, recalcular on-the-fly (mesmo algoritmo atual) e gravar de volta no `car_protected_overlap` (auto-repair). Source: user-confirmed — pré-cálculo batch é o caminho feliz, mas o sistema precisa se recuperar de imports parciais.
- **Decision:** TTL Redis `car:protected:<COD>` **mantém 86400s (24h)** — user-confirmed override da recomendação inicial. Justificativa do usuário: dados UC/TI não atualizam com essa frequência; o operador já sabe quando re-rodar o batch (após download novo de `conservation_units.json`/`indigenous_lands.json`). Como o resultado vem do SQLite pré-calculado (fonte da verdade), o TTL longo do Redis é seguro — só evita recomprimir o JSON a cada request.
- **Assumption:** `conservation_units.json` e `indigenous_lands.json` mudam <1×/mês; pré-cálculo pode ser re-rodado por cron ou manualmente quando o operador baixar JSON novo. Source: code @ `backend-lua/app/lookups/conservation_units_lookup.lua:55-78` (ingest manual via caminho de arquivo).
- **Decision:** reimport CAR invalida o pré-cálculo **por UF**. `tools/import_car.lua:48-49` faz `DELETE FROM car_data` e `DELETE FROM car_rtree` por UF (a ferramenta aceita `[UF ...]` como argumento) — portanto, **quando o operador reimportar uma UF, apenas os imóveis dessa UF perdem o pré-cálculo**. Source: code @ `tools/import_car.lua:48-49`. Fix escolhido: `import_car.lua` apaga de `car_protected_overlap` **apenas os códigos da UF sendo reimportada** (`DELETE FROM car_protected_overlap WHERE cod_imovel IN (SELECT cod_imovel FROM car_data WHERE uf = ?)` **antes** do `DELETE FROM car_data`), para não servir overlaps órfãos. Documentar no RUNBOOK que reimportar uma UF requer re-rodar `warm_car_protected_overlap.lua <UF>` em seguida. O auto-repair da rota cobre imóveis novos até o batch rodar. Não se inicia warm automaticamente no final de `import_car` porque pode levar horas.
- **Assumption:** o número de imóveis CAR é da ordem de 10⁴–10⁵ (não há números explícitos no repo). Pré-cálculo de 100k imóveis × grid 64² ≈ 410M ray-casts no total → viável em batch offline (estimativa: <30min em 1 worker por UF; paralelizável por UF). Source: code @ `car_import.lua:113`.
- **Assumption:** o rtree do `car.db` cobre todos os imóveis. Source: code @ `backend-lua/app/lookups/car_lookup.lua:155-169`.
- **Decision:** **NÃO** pré-calcular para imóveis com `area < MIN_PRECOMPUTE_HA` (default `1.0 ha`) — imóveis minúsculos (ruas, posses) geram bbox degenerado e a amostragem não ajuda. Default `1.0 ha` é seguro; configurável por env `PROTECTED_OVERLAP_MIN_AREA_HA`. Source: default.
- **Decision:** schema `car_protected_overlap` inclui coluna `version_key TEXT`. A `version_key` é um hash/canonical stamp das **fontes de geometria + parâmetros do algoritmo que afetam a sobreposição percentual** (ex: SHA256 curto de `conservation_units.json` + `indigenous_lands.json` + `OVERLAP_SAMPLES`), **NÃO inclui `OVERLAP_SUSPECT`**. A rota trata `version_key != current` como stale. O `status` (ok/suspeito/indeterminado) é re-avaliado em runtime comparando `max_pct` com o `OVERLAP_SUSPECT` atual, então ajustes finos de threshold não invalidam o pré-cálculo. Redis também carrega/salva `version_key` no payload (SHOULD-FIX #7). Source: code @ `routes/car.lua:177`.
- **Unit convention (CONSIDER #4):** `MIN_PRECOMPUTE_HA` é em **hectares**; `car_data.area` é gravada como o `area` GeoJSON do SICAR (em hectares segundo convenção do CAR; `car_lookup.get_by_cod_imovel` retorna como `area_ha`). Comparação direta `area >= MIN_PRECOMPUTE_HA` é válida sem conversão.
- **Decision:** testes existentes (`tests/test_car_protected.lua`) continuam rodando contra o modo **fallback** (sem `car_protected_overlap` populado). Adicionar 1 caso novo: `car_protected_overlap` populado → rota lê direto dele.

## Files to touch

### `backend-lua/app/car_import.lua` (MODIFICAR) — done
- O que muda:
  1. Adicionar `create_car_protected_schema(conn)` com o schema completo (`cod_imovel`, `sampled`, `overlaps`, `status`, `max_pct`, `threshold`, `version_key`, `computed_at`) + `idx_car_protected_computed_at`.
  2. Em `tools/import_car.lua` (que usa `car_import.create_schema`): antes do `DELETE FROM car_data` de uma UF, executar `DELETE FROM car_protected_overlap WHERE cod_imovel IN (SELECT cod_imovel FROM car_data WHERE uf = ?)` (MUST-FIX #1 + SHOULD-FIX #7). Isso evita overlaps órfãos sem destruir o pré-cálculo das outras UFs.
- Chamada no início de `import_file`? **Não** — o batch tem seu próprio script e abre sua própria conexão. `create_car_protected_schema` é helper invocado pelo batch e pelo import.

### `backend-lua/tools/warm_car_protected_overlap.lua` (NOVO) — done
- CLI: `lua5.1 tools/warm_car_protected_overlap.lua [UF]` (sem arg = todos).
- Função `_M.run_batch(uf_filter)`:
  1. `env.load_dotenv`, `db.init_db` (para lookup UC/TI em JSONB).
  2. `ti.load_indigenous_lands()`, `uc.load_conservation_units()`.
  3. `car_import.create_schema(car_conn)` (idempotente), `car_protected_overlap.ensure_schema(car_conn)`.
  4. SELECT imóveis do `car_data` filtrando por UF e `area >= MIN_PRECOMPUTE_HA`.
  5. Para cada imóvel: rodar o mesmo algoritmo de `routes/car.lua:188-241` (`sample_overlap` com grid dinâmico). Regra do grid:
     - Se `area_ha < 1.0`: pula (não entra no batch).
     - Se `1.0 <= area_ha < 10.0`: grid 32² (1024 pontos). Justificativa: imóveis abaixo de 10ha têm bbox pequeno; 1024 pontos ainda produzem `interior >= MIN_INTERIOR (20)` para formas compactas, e 64² seria trabalho desnecessário. Imóveis irregulares (muito alongados) podem cair em `interior < 20` → status `indeterminado`; o runtime reclassifica via fallback.
     - Se `area_ha >= 10.0`: grid 64² (4096 pontos). Justificativa: imóveis maiores precisam de mais pontos para manter a densidade amostral e não subestimar overlaps finos na borda de UCs/TIs.
     - Adaptive sampling **desligado** no batch (determinístico).
  6. **Bulk upsert em chunks de 1000** (SHOULD-FIX #6): chama `car_protected_overlap.bulk_upsert(rows)` que abre `BEGIN`, faz N `INSERT ... ON CONFLICT ... DO UPDATE ...`, e `COMMIT`. Isso reduz drasticamente o número de round-trips Lua→SQLite vs UPSERT unitário. O padrão é espelhado em `db.bulk_upsert_fires` (`db.lua:407-441`).
  7. Ao finalizar, se o warm foi bem-sucedido, invalidar o pattern Redis `car:protected:*` via `redis.delete_pattern("car:protected:*")` (SHOULD-FIX #8). Isso força o próximo request de cada imóvel a ir direto ao SQLite pré-calculado, evitando o primeiro request lento após warm.
  8. Logar progresso a cada 1000 imóveis + ETA.
- PRAGMAs da conexão writable: espelhar `tools/import_car.lua:42-44` — `synchronous=OFF`, `cache_size=-200000`, `temp_store=MEMORY`, `journal_mode=WAL` (CONSIDER #12).
- **Performance** (MUST-FIX #3): single-worker vai ser lento para 100k imóveis × grid × candidatos UC/TI. Estimativa realista: dezenas de minutos a horas por UF, dependendo do número de candidatos e vértices. Solução adotada:
  - **Paralelização por UF** é a principal estratégia: cada UF roda seu próprio subprocess `lua5.1 tools/warm_car_protected_overlap.lua <UF>` em paralelo via `xargs -P` ou systemd timers.
  - **Dentro de uma UF**, sequential é aceitável (cada UF tem tipicamente 5-20k imóveis).
  - Documentar no RUNBOOK o comando para re-warm completo com 8 workers.
  - **Não adicionar paralelismo in-process no script Lua** — subprocess + UF é mais simples e crash-safe.
  - **Benchmark obrigatório no Verification:** cronometrar 100 imóveis representativos e extrapolar.
- Erro paths:
  - `car.db` ausente → bail com mensagem clara (não é fatal pro server).
  - Lookups UC/TI ausentes → bail (o batch precisa das geometrias).
  - geom inválida (`cjson.decode` falha) → log warn + skip do imóvel.
  - `cjson.encode` em overlaps >1MB (CONSIDER #2) → log warn + skip (não engole; investigação necessária).

### `backend-lua/app/lookups/car_protected_overlap.lua` (NOVO módulo de lookup) — done

> Decisão revista após MUST-FIX #2 do reviewer: `db.lua` é dono exclusivo do pool do `yvy.db` (`db.lua:152-180`); não cabe helpers do `car.db` lá. O módulo novo é co-locado com os outros lookups do CAR e segue o mesmo padrão singleton (`car_lookup.lua`, `conservation_units_lookup.lua`).

- O que muda: módulo novo com 3 funções.
- Function: `_M.ensure_schema(conn)` — `CREATE TABLE IF NOT EXISTS car_protected_overlap (cod_imovel TEXT PRIMARY KEY, sampled INTEGER, overlaps TEXT, status TEXT, max_pct REAL, threshold REAL, version_key TEXT, computed_at TEXT);` + `CREATE INDEX IF NOT EXISTS idx_car_protected_computed_at ON car_protected_overlap(computed_at);` (índice em `status` foi descartado pelo CONSIDER #1 — toda leitura vai por PK; índice em `computed_at` permite re-warm seletivo no futuro).
- Function: `_M.get(cod_imovel)` → SELECT 1 linha por PK, retorna `{sampled, overlaps, status, max_pct, threshold, version_key, computed_at}` (com `overlaps` já decodificado de JSON) ou nil. Rota checa `version_key == current_version_key()` — mismatch = stale.
- Function: `_M.current_version_key()` → retorna o stamp atual (hash de UC/TI + `OVERLAP_SAMPLES`). Usado pelo batch, pela rota e pelos testes.
- Function: `_M.upsert(cod_imovel, result, computed_at)` → UPSERT simples unitário. Usado **apenas** pelo auto-repair da rota runtime, e somente quando habilitado.
- **Auto-repair throttled** (MUST-FIX #4): a rota runtime, ao cair no fallback, **não** grava automaticamente no `car_protected_overlap` para evitar thundering herd de escritas SQLite no request thread. Em vez disso, usa `redis.setnx("car:protected:repair_lock:" .. cod, "1", 300)`; se conseguir o lock, chama `car_protected_overlap.upsert(...)` em pcall (fire-and-forget). Isso garante que, mesmo que 100 requests simultâneos batam no mesmo imóvel novo, só 1 escreve no SQLite. Se `setnx` falhar ou Redis estiver indisponível, o request retorna normalmente sem escrever.
- Function: `_M.bulk_upsert(rows)` → recebe lista `{cod_imovel, sampled, overlaps, status, max_pct, threshold, version_key, computed_at}` e faz `BEGIN ... COMMIT` com N UPSERTs. Usado exclusivamente pelo batch (SHOULD-FIX #6).
- **Conexão writable dedicada** (resolve MUST-FIX #1): abre sua própria handle `sqlite3.open(CAR_DB_PATH)` (sem `query_only=ON`) e cacheia em escopo de módulo. Não conflita com a handle read-only do `car_lookup.lua:198-203`. Custo: 1 handle extra.
- PRAGMAs: na primeira abertura, aplicar `journal_mode=WAL`, `synchronous=OFF`, `cache_size=-200000`, `temp_store=MEMORY` (CONSIDER #12).
- **Path resolution** (SHOULD-FIX #6): o módulo importa `app.lookups.car_lookup` e reusa a mesma lógica de resolução de `CAR_DB_PATH` (ou `car_lookup` exporta uma função `db_path()`). Não abrir um caminho hardcoded diferente do lookup principal.
- Erro paths: `cjson.encode` falhando em payload >1MB → retornar false; caller decide.

### `backend-lua/app/routes/car.lua` (MODIFICAR) — done

- O que muda: `get_protected_overlap` lê primeiro do SQLite `car_protected_overlap`; só cai no caminho Monte-Carlo se faltar ou estiver stale. Adiciona campo `source: "precomputed" | "live"` na resposta (campo novo, backward-compatible).
- Function: `_M.get_protected_overlap(ctx)`
  - **Novo fluxo:**
    1. Validar `cod_imovel` (já existe).
    2. Tentar Redis (TTL 86400) → se hit, retornar.
    3. Tentar SQLite `car_protected_overlap` via `car_protected_overlap.get(cod)`. Se existir, `version_key` bater com `car_protected_overlap.current_version_key()` E `now - computed_at < STALE_DAYS` (default 30 dias, env `PROTECTED_OVERLAP_STALE_DAYS`):
       - Reconstruir payload `{cod_imovel, sampled, overlaps, status, threshold, max_pct, cached=false, source="precomputed", version_key}`.
       - Cachear Redis 86400s.
       - Retornar.
    4. **Fallback:** rodar o caminho Monte-Carlo atual inteiro (do jeito que está hoje, sem mudanças).
    5. **Re-avaliação de status:** se o dado veio do pré-calculado mas `OVERLAP_SUSPECT` mudou desde o cálculo, recalcular `status` a partir de `max_pct` sem rodar Monte-Carlo novamente. O `threshold` retornado ao cliente é sempre o `OVERLAP_SUSPECT` atual.
    6. **Auto-repair throttled** (MUST-FIX #4): ao final do fallback, se `prop.area_ha >= MIN_PRECOMPUTE_HA`:
       - Tenta `redis.setnx("car:protected:repair_lock:" .. cod, "1", 300)`.
       - Se conseguir o lock, chama `car_protected_overlap.upsert(cod, result, now)` em pcall (fire-and-forget).
       - Se não conseguir ou Redis indisponível, retorna sem escrever.
       - Se `< MIN_PRECOMPUTE_HA`, **não** grava (SHOULD-FIX #8).
- TTL: `CACHE_TTL = 86400` (mantém 24h). Constante no topo do arquivo. Não muda.
- Data shapes: igual ao atual. Adiciona campo `source: "precomputed" | "live"` na resposta pra diagnóstico.

### `backend-lua/tests/test_car_protected.lua` (MODIFICAR) — done
- Reusar `tests/fixtures/car_sample.json` existente e seedar `car_protected_overlap` manualmente no setup dos testes novos (não criar fixture nova `.lua` ou `.json` confusa — resolve MUST-FIX #3). Se quisermos cobrir imóvel <1ha, adicionar 1 feature em `tests/fixtures/car_small.json` (dedicada) e carregá-la via import no setup daquele caso.
- Adicionar caso: `version_key` mismatch → rota recalcula (`source="live"`) ou, se ainda dentro do `STALE_DAYS`, re-avalia `status` a partir de `max_pct`.
- Adicionar caso: `car_protected_overlap` populado → `GET /api/car/protected?cod_imovel=X` retorna payload com `source="precomputed"` e **não** chama o fallback.
- Adicionar caso: `car_protected_overlap` stale (computed_at > STALE_DAYS) → rota recalcula (verifica `source="live"`).
  - **Estratégia fixa:** o teste seta `PROTECTED_OVERLAP_STALE_DAYS=0` via `env.set` no setup, popula uma row com `computed_at = helpers.days_ago(0)` (hoje), e verifica `source="live"`. Usar `helpers.days_ago` evita date-bomb (common-mistake #1).
- Adicionar caso: `car_protected_overlap` ausente → `source="live"` (cobre fallback).
- Cobertura: imóvel grande vs imóvel < `MIN_PRECOMPUTE_HA` — este último deve rodar fallback e **não** deixar row em `car_protected_overlap` (auto-repair guardado).
- **Teardown completo** (MUST-FIX #2 / common-mistake #2): no `teardown`, além de deletar Redis keys (`car:protected:*`), fazer `DELETE FROM car_protected_overlap` no `car.db` do teste. O setup também faz `DELETE` para garantir estado limpo, mas o teardown é a barreira de segurança que roda em caso de falha.

### `backend-lua/Makefile` (MODIFICAR — adicionar target) — done
- Target `warm-car-protected`: chama o script batch (`lua5.1 tools/warm_car_protected_overlap.lua`).
- Comentário explicando quando rodar (após import CAR novo, ou após update de UC/TI JSON).
- **NÃO** adicionar target `test` central aqui (SHOULD-FIX #4): o `backend-lua/Makefile` atual só tem `all/clean/run` e não existe `tests/run.lua`. Os testes continuam sendo invocados individualmente (`lua5.1 tests/test_*.lua`) pela CI/manualmente.

### `RUNBOOK.md` (MODIFICAR — adicionar seção curta) — done
- "Como regenerar o pré-cálculo CAR × UC/TI":
  1. Após reimportar CAR (`lua5.1 tools/import_car.lua ...`): o `car_protected_overlap` é apagado junto — re-rodar `make warm-car-protected` (ou `lua5.1 tools/warm_car_protected_overlap.lua`).
  2. Após baixar `conservation_units.json` / `indigenous_lands.json` novos: re-rodar o warm.
  3. Troubleshooting: imóvel retorna `source="live"` sempre → verificar se `car_protected_overlap` tem row e se `version_key` bate com `PROTECTED_OVERLAP_SUSPECT`.

## Edge cases

- **Imóvel com `area_ha < MIN_PRECOMPUTE_HA`** (1 ha): pulado no batch → fallback live na rota; auto-repair **não** grava de volta (SHOULD-FIX #8). Verificar que o teste cobre isso.
- **`car.db` com rtree ausente** (db legado): `car_lookup.get_by_cod_imovel` já tem fallback (geometry walk). O batch pega todos via SELECT direto em `car_data`, então não precisa do rtree pra iterar — só pra bbox lookup, que é o que o batch já recebe.
- **UC/TI mudam enquanto o batch roda**: como o batch carrega UC/TI na memória UMA vez (igual ao runtime), ele é autocontido. Re-rodar após mudança é trivial.
- **Redis indisponível no startup**: o caminho SQLite funciona sozinho. Redis vira um fast-path opcional.
- **CAR import novo (novo imóvel adicionado ao `car.db` via `tools/import_car.lua`)**: o novo imóvel NÃO aparece em `car_protected_overlap` → cai no fallback live (que auto-repara gravando de volta). Próximo request → vem do pré-calculado. Sem migração necessária.
- **Dois batches concorrentes** (race): UPSERT é idempotente (PK = cod_imovel). O último a escrever ganha. Sem lock necessário.
- **Backup do `car.db` antes do warm** (SHOULD-FIX #10): na primeira execução (ou quando a tabela ainda não existe), o script faz `VACUUM INTO` ou cópia de arquivo do `car.db` antes de escrever `car_protected_overlap`. O `car.db` é cold cache; corrompê-lo seria crítico.
- **Impacto de storage** (CONSIDER #12): a tabela `car_protected_overlap` pode adicionar 100-500MB ao `car.db` (estimativa: 100k imóveis × 1-5KB de JSON). Documentar no RUNBOOK.
- **`overlaps` JSON grande / cjson 1MB**: polígono grande + muitos candidatos → JSON de centenas de KB. SQLite TEXT aceita; Redis serializa sem problema. O batch deve pular+logar se `pcall(cjson.encode, ...)` falhar (limite raro, mas possível). Source: code @ `routes/car.lua:316` — payload atual já passa pelo mesmo `cjson.encode`.
- **Imóvel cuja geometria é MultiPolygon com 100+ anéis**: ray-cast é O(anéis) por ponto. Já é o comportamento atual; batch herda. Não é regressão.

## Verification

- **Test command:** cada teste é standalone. Rodar: `cd backend-lua && lua5.1 tests/test_car_protected.lua`. O `Makefile` atual não tem target `test` (SHOULD-FIX #4); este plano **não** adiciona um target `make test` central porque não existe runner `tests/run.lua`. Em vez disso, adiciona target `warm-car-protected` ao Makefile e documenta que CI/testes invocam os arquivos `lua5.1 tests/test_*.lua` individualmente.
- **Tests to add/update:**
  - `test_car_protected.lua`: 3 casos novos (precomputed-hit, stale-fallback, absent-fallback) + teardown com cleanup de `car_protected_overlap` e Redis.
- **Manual:**
  1. Subir `yvy-server` + Lua backend.
  2. `lua5.1 tools/warm_car_protected_overlap.lua` → ver log de progresso.
  3. `curl :5000/api/car/protected?cod_imovel=MT-1234567-ABCD...&apikey=testkey` → response deve ter `source="precomputed"`.
  4. Comparar latência antes/depois com `time curl ...` no mesmo imóvel (cold path).
  5. Invalidar Redis: `redis-cli DEL car:protected:<COD>` → re-curl → resposta vem do SQLite, ainda rápida.
  6. **Benchmark:** rodar `time lua5.1 tools/warm_car_protected_overlap.lua RO` e medir throughput (imóveis/segundo); extrapolar para todas as UFs e decidir número de workers paralelos.
- **Done criteria:** p99 de `/api/car/protected` em prod cai para <50ms (warm), <5ms (cache hit), e cold (imóvel novo) cai pra <500ms (auto-repair escreve em background, próxima request é hit).

## Standards / common-mistakes referenced

- **Detached process pattern** (modelo `tools/deter_protected_alerts.lua`, `tools/warm_ti_at_risk.lua`) — batch sempre roda fora do request loop.
- **Idempotência de schema** (`create_*_schema` em `car_import.lua:65-79`) — CREATE TABLE IF NOT EXISTS, sem migration step.
- **Redis como fast-path opcional** (não fonte da verdade) — alinhado com `routes/deter.lua:73-79` (cache stats) e o uso geral de `redis` no projeto.
- **pcall em escritas offline** (auto-repair não derruba request) — alinhado com o padrão de `db.lua:patch_fire_jsonb`.

## Estimated scope

**M** — 1 arquivo novo (script batch ~150 linhas), 4 arquivos modificados com mudanças pequenas/médias, 3+ testes novos. Sem mudança de API pública, sem schema no `yvy.db`, sem dependência nova.

## Open questions (CONSIDER from review)

- **CONSIDER #6 (memoization de `is_loaded()`):** `car_lookup.lua:185-194` tem TTL 60s no check de count. Após `import_car.lua` adicionar imóveis, o runtime pode brevemente achar CAR indisponível até o TTL expirar. Não é regressão vs hoje (já existe), mas vale nota no RUNBOOK: re-rodar `warm_car_protected_overlap` após ingest CAR pra manter os dois stores coerentes.
- **CONSIDER (lookup spatial index):** `geo.point_in_polygon` itera O(n_vertices) por ponto. Para TIs grandes (algumas têm 5k–20k vértices no outer ring), o batch pode acelerar pré-calculando um **grid espacial sobre as TIs/UCs** (similar ao `build_veg_grid` em `db.lua:1087-1100`). Fora do escopo deste plano (escala só importa no batch full-warm); candidato natural pra um plano de otimização de lookups separado.
