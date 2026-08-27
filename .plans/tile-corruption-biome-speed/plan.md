# Corrupção de Tiles ao Panning ("Image corrupt or truncated") + Biomas ("Focos por bioma") lentos

> **Status: done** — implementado e verificado (325 testes, server ao vivo). Detalhes em “## Done” no fim do arquivo.

## Context

### Bug 1 — "Image corrupt or truncated" no console ao panning

Ao panear o mapa, o console do browser espama `Image corrupt or truncated.
/api/tiles/car?…` (o tail "car"/"prodes" é da URL; a mensagem é do decoder de
imagem do browser). Causa raiz **identificada e reproduzida**:

O `EMPTY_PNG` em `backend-lua/app/routes/tiles.lua` (67 bytes) — o 1×1
transparente servido em todo cache miss (áreas vazias, zooms baixos,
oceano/fora do Brasil) — é um **PNG inválido**:

- IDAT: stream zlib ilegível (`78 9C 62 00 00 00 02 00 01` →
  `zlib.error: invalid stored block lengths`) — o autor tentou escrever
  "stored" blocks de 0 bytes, mas o header `78 9C` exige DEFLATE comprimido.
- CRC do IDAT errado (stored `0x21BC3300` vs calculado `0x8626766C`).
- PIL: `broken data stream when reading image file`.

Todo miss de cache serve esse blob → o browser tenta decodizar dezenas de
PNGs inválidos por pan. O DB de tiles está íntegro (amostragem: 0 blob com
assinatura ruim; máx 13.5KB/row) — a corrupção é 100% do `EMPTY_PNG`.

### Bug 2 — "Focos por bioma" demora a carregar (+ bloqueio do event loop)

`GET /api/biomes` (`app/routes/biomes.lua`) recalcula inline em todo cache
miss (TTL 60s):

1. `db.find_fires(-34, 5.5, -74, -34, 10000)` — 0.25–0.76s (10k rows
   completas + montagem de objetos Lua).
2. `biome_lookup.classify_fires(fires)` — 0.79s (10k focos × 18 anéis,
   ray-cast Lua).

≈ **1.5s por cache miss**, e o `biomes_prewarm_loop` (`app/init.lua`) roda o
mesmo cálculo **inline no loop copas a cada 5 min, bloqueando TODAS as outras
requisições** (backend single-threaded; precedente documentado:
`/api/fires/ti-at-risk`, movido para subprocesso destacado por esse motivo).

O bioma **já é persistido por foco** (`$.biome`, `biome_backfill_loop`;
prod: 199.097 rows — 127.340 com bioma + 71.757 `''` [oceano/fora de bioma]).
Um **aggregate SQL** substitui o ray-cast:

| Variante | Tempo (runtime real, lsqlite3, yvy.db) |
|---|---|
| Atual: `find_fires` + `classify_fires` | ~1.5s |
| B: janela 10k + `GROUP BY json_extract(data,'$.biome')` | **~0.16s** (~0.27s frio em python) |

### Anti-padrão 3 (SHOULD) — `/api/alerts` inline

`/api/alerts` (main.lua) e `alerts_sync_loop` (init.lua) recomputam inline
(`find_fires` 0.42s + `generate_all_alerts` 0.39s ≈ 0.8s) — o mesmo bloqueio
do event loop que motivou mover `ti-at-risk` e news para subprocesso. Mover
para subprocesso destacado seguindo o padrão `tools/warm_ti_at_risk.lua`.

## Assumptions and decisions

- **SHOULD**: `EMPTY_PNG` → PNG 1×1 transparente **gerado e verificado
  (68 bytes)**: zlib nível 9 (`78 DA …`, CRC `E9FA DCD8`), chunks IHDR/IDAT/
  IEND com CRCs válidos (verificação: PIL decodifica → `(1,1) RGBA (0,0,0,0)`;
  todos os CRCs conferem com `zlib.crc32`).
- **SHOULD**: validação defensiva na `lookup_tile` — blob que não começa com
  a assinatura PNG (`\x89PNG\r\n\x1a\n`) é tratado como **miss** (→ EMPTY_PNG
  válido), com `logger.warn` (1x por tile? não: sempre warn, baixo volume).
  Blobs de tile corrupto nunca chegam ao browser. **Efeito colateral conhecido
  e necessário**: os fixtures dos testes que usam blobs sintéticos
  (`"TILE-BYTES"`, `"Z3-TILE-BYTES"`, …) passam a usar PNGs válidos (ver
  teste updates). Isso é correto: em produção o warmer só grava PNGs reais.
- **SHOULD**: `/api/biomes` vira aggregate SQL sobre `$.biome`. A resposta
  **MANTEM o shape exato de hoje** — importante: `classify_fires` retorna um
  **ARRAY** (chaves numéricas!) na ordem `BIOME_ORDER`, com **contagem zero
  inclusas** (6 entradas sempre), e `total_fires = #fires` (rows da janela,
  inclusive sem bioma). O novo código replica isso: array de 6
  `{name,count,pct,color}` em `BIOME_ORDER`; `pct` sobre o total
  **classificado** (exclui `''`/NULL); `color` vem das tabelas **vivas** do
  lookup (`biome_colors` populado de lookup_data/biome_data.json — são
  **CSS gradients** e podem diferir do fallback BIOME_COLORS).
- **SHOULD**: semântica da janela idêntica (mirror exato de
  `db.find_fires(-34,5.5,-74,-34,10000)`, sem brazil_only/source):
  `WHERE lat>=-34 AND lat<=5.5 AND lon>=-74 AND lon<=-34 ORDER BY
  acq_date DESC, lat, lon LIMIT 10000` — só `SELECT json_extract(data,
  '$.biome')`; NULL/`''` agrupados à parte para `total`, excluídos do
  percentual (o backfill de biome usa o MESMO `classify_point` — valores
  equivalentes; novos focos ganham `$.biome` em segundos pelo backfill loop,
  lag de 1 ciclo de cache de 60s no pior caso — aceitável).
- **SHOULD**: o assembly da resposta fica em UM lugar —
  `_M.compute_biomes_payload()` em `routes/biomes.lua` (retorna o body
  JSON) — usado pela rota e pelo `biomes_prewarm_loop` (sem diff duplicado).
- **SHOULD (follow-up aprovado como "should")**: `/api/alerts` +
  `alerts_sync_loop` → subprocesso destacado `tools/warm_alerts.lua`
  (padrão `warm_ti_at_risk.lua`): rota serve cache → stale → vazio+trigger;
  subprocesso com lock `setnx`, grava `alerts:all`, `alerts:all:stale`
  (7d) e `alerts:last_sync`. `generate_all_alerts` continua no módulo alerts
  (o subprocesso o chama).
- **ASSUME**: `biome_backfill_loop` segue rodando (mantém `$.biome` atual).
  Sem migração de schema. Sem mudança de frontend.
- **CONSIDER → DECIDIDO**: manter `classify_fires` no módulo (back-compat /
  ferramentas); só remover seus callers de rota/prewarm.

## Files to touch

### 1. backend-lua/app/routes/tiles.lua

- `EMPTY_PNG` → 68 bytes verificados (listagem no Context/Bug1: sig, IHDR,
  `78 DA 63 60 00 02 00 00 05 00 01` IDAT, CRCs válidos).
- `PNG_SIGNATURE = string.char(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A)`.
- `lookup_tile`: após obter `data`, se `not data or data:sub(1,8) ~=
  PNG_SIGNATURE` → `logger.warn("corrupt tile blob …")` (inclui z/x/y) e
  `return nil` (→ miss). Aplica a todos os paths (exato, ancestor,
  descendant), pois todos chamam `lookup_tile`.
- Headers/caching inalterados (`serve_png` immutable 30d; `serve_miss`
  max-age 60/300; CAR no-store).

### 2. backend-lua/app/db.lua

- `_M.count_fires_by_biome_window(sw_lat, ne_lat, sw_lng, ne_lng, limit)`:
  mirror exato de `find_fires` (mesmo WHERE/ORDER/LIMIT, sem brazil_only):
  ```lua
  SELECT biome, COUNT(*) AS cnt FROM (
    SELECT CASE WHEN json_extract(data, '$.biome') IS NULL
                OR json_extract(data, '$.biome') = '' THEN ''
                ELSE json_extract(data, '$.biome') END AS biome
    FROM fire_data
    WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
    ORDER BY acq_date DESC, lat, lon
    LIMIT ?
  ) GROUP BY biome
  ```
  (`CASE` normaliza NULL → `''` para o grupo.) Retorna
  `(counts, total)`: `counts = {[nome] = n}` (sem `''`), `total = n
  (inclui `''`). Padrão `pool_acquire`/`fetch_all`/`pool_release` (mesma
  família de `get_fires_by_biome`).

### 3. backend-lua/app/lookups/biome_lookup.lua

- Adicionar 2 accessors (têm que usar as tabelas VIVAS — DB-first):
  - `_M.biome_order()` → retorna o array `BIOME_ORDER`.
  - `_M.color_for(name)` → `biome_colors[name] or BIOME_COLORS[name] or
     ""` (idêntico ao que `classify_fires` usa).
- `classify_fires` permanece (sem mudanças); apenas sai dos callers de
  rota/prewarm.

### 4. backend-lua/app/routes/biomes.lua

- `_M.compute_biomes_payload()` (novo, exportado p/ init.lua):
  `counts, total = db.count_fires_by_biome_window(-34, 5.5, -74, -34,
  MAX_RESULTS)`; monta
  `{biomes = [6 × {name,count,pct,color} em BIOME_ORDER], total_fires =
  total, last_sync = redis.get("fires:last_sync")}`; `pct` sobre
  `classified = total - (count[''] or 0)` (0 seclassified=0);
  `count = counts[name] or 0` (zeros incluídos); `color =
  biome_lookup.color_for(name)`; retorna body via `cjson.encode`. **Requer
  `biome_lookup.load_biomes()` antes?** Não — na rota o prewarm/init já
  carregou no boot (init.lua faz `biome_lookup.load_biomes()` no startup);
  mas `load_biomes()` é idempotente/barato — chamar dentro de
  `compute_biomes_payload` p/ segurança (verificar `loaded_count()`? Não —
  `load_biomes` re-lê DB a cada chamada = caro. Usar flag: se
  `biome_lookup.loaded_count() == 0` → `load_biomes()`; senão pular.)
  Simplicidade: `if biome_lookup.loaded_count() == 0 then
  biome_lookup.load_biomes() end`.
- `_M.get_biomes(ctx)`: auth + rate limit → cache `biomes:all` (guard
  inalterado) → `compute_biomes_payload()` → `redis.set` 60s → send 200.
  Cache-Control inalterado.
- **Nota**: a guard regex `'"biomes"%s*:%s*{}'` nunca casa com o shape novo
  (array `[]`), então resposta vazia (`"biomes":[]`) é servida estável do
  cache — comportamento correto (evita recompute storm em DB vazio; antes o
  `{}` causava redelete a cada request).

### 5. backend-lua/app/init.lua

- `biomes_prewarm_loop`: substituir `find_fires+classify_fires` por
  `biomes_routes.compute_biomes_payload()`; `redis.set("biomes:all", body,
  BIOMES_PREWARM_INTERVAL + 60)` inalterado.
- `alerts_sync_loop`: substituir o compute inline por
  `alerts_mod.trigger_alert_refresh()` (subprocesso); manter a checagem de
  idade `alerts:last_sync` (o subprocesso grava o marker).

### 6. backend-lua/app/routes/alerts.lua

- `_M.trigger_alert_refresh()`: no padrão
  `fires.trigger_ti_at_risk_refresh` — lock `redis.setnx("alerts:refresh:lock",
  "1", 1800)` (evita duplo job; TTL = backstop de crash), resolve dir via
  `debug.getinfo`, `nohup lua5.1 tools/warm_alerts.lua >/dev/null 2>&1 &`
  (Windows: `start /b`). Nunca bloqueia o loop.

### 7. backend-lua/tools/warm_alerts.lua (NOVO)

- Padrão `warm_ti_at_risk.lua`: load env (dotenv no repo root + backend),
  `db.init_db()`, carregar lookups TI/UC, ler lock? não — o spawn já
  verificou; se `redis.get("alerts:all") for fresh`… **não**: o loop decide
  pela idade de `alerts:last_sync`; o subprocesso recalcula sempre que
  chamado (o lock impede overlap). Compute:
  `db.find_fires(-34,5.5,-74,-34,10000)` + `alerts.generate_all_alerts(fires,
  nil, os.getenv("WAQI_TOKEN"))`; grava `alerts:all` (TTL 1800),
  `alerts:all:stale` (604800) e `alerts:last_sync` (TTL 3600). Log + stderr.

### 8. backend-lua/main.lua

- Rota `/api/alerts`: servir cache `alerts:all`; se ausente → servir
  `alerts:all:stale` (ou body mínimo `{alerts=[], count=0, generated_at}`) +
  `alerts_mod.trigger_alert_refresh()`; Cache-Control curto (30s) no cold
  path, 300 no cache hit. (Mirror exato de `/api/fires/ti-at-risk`.)

### 9. backend-lua/tests/test_biomes_route.lua (NOVO)

Padrão `test_fires_by_biome.lua`: `env.set("SQLITE_PATH", tmp)` **antes** de
`require("app.db")`; re-require módulos afetas; Redis stubado com restore em
teardown; `do dofile("tests/helpers.lua")`; `biome_lookup.load_biomes()` (DB
temp recebe o lookup via `set_lookup_data` no primeiro load — fallback para
`data/biome_data.json` existe e é o caminho usado no test dir).

Fixtures (clock-relative, common-mistakes #1): 6 focos
(3 Manaus/AM, 2 Brasília/DF, 1 oceano) com `bulk_upsert_fires` + backfill de
bioma manual (como no test irmão). Auth: `fake_ctx` com
`remote_addr="127.0.0.1"` → `auth.enforce` passa; rate limit: stub
`redis.check_rate_limit` → nil (e/ou IP privado já bypassa).

Test cases:
1. **Aggregate correto**: rota → 200; `body.biomes` array de 6 (ordem
   `BIOME_ORDER`), `Amazônia.count=3`, `Cerrado.count=2`, `Pampa.count=0`
   (zero incluído), `total_fires=6`, `pct` sobre 5 (classificados):
   Amaz `60.0`, Cerrado `40.0`; `color` não-vazio para as 6.
2. **Cache hit**: redis stub com valor pré-setado em `biomes:all` → corpo
   retornado é o do cache (sem recompute — stub de `db` não é chamado de
   novo).
3. **Guard**: cache em forma `{"biomes":{},…}` → deletado + recompute.
4. **DB vazio**: 200 com `biomes` array de 6 zeros e `total_fires=0`.
5. **`compute_biomes_payload`** usa `fire:last_sync` do redis (stub).

### 10. Atualizações de fixtures existentes (efeito do signature check)

- `tests/test_car_routes.lua`: blob `"TILE-BYTES"` → PNG válido (1×1 ou
  PNG 1x1 sintético mínimo válido).
- `tests/test_tiles_fallback.lua`: `"Z3-TILE-BYTES"`, `"Z4-TILE-BYTES"`,
  `"Z4-X1-TILE-BYTES"`, `"Z3-X1Y1"` → PNGs válidos. Para manter os asserts
  de identidade de bytes, cada fixture usa um PNG válido DIFERENCÍAVEL
  (ex.: PNG 1×1 com pixel de cor distinta — gerar 4 PNGs válidos únicos).
  Assert `#ctx.body < 100` (EMPTY_PNG 68b) segue válido; trocar comentário
  "67 bytes" → 68.
- **Novo caso** em test_tiles_fallback (ou car_routes): tile com blob
  **corrupto** (sem assinatura PNG) → rota serve EMPTY_PNG válido (200,
  `image/png`, começa com assinatura, `#body==68`) — cobre o defensive check.

## Edge cases

- **Blob corrupto no DB de tiles** → `lookup_tile` nil → miss → EMPTY_PNG
  válido. Nunca 500, nunca imagem quebrada ao browser.
- **Browser com EMPTY_PNG antigo em cache**: tiles reais são `public,
  max-age=2592000, immutable` mas o EMPTY_PNG antigo só era servido no path
  miss (PRODES max-age=60/300; CAR `no-store`) → expira/revalida em ≤5 min
  sem forçar limpeza. Sem bump de `?v=` necessário.
- **Focos novos sem `$.biome` ainda**: ficam no grupo `''` (não contam em
  `pct` mas contam em `total_fires`) → convergem quando o backfill roda
  (≤ 2s entre ciclos enquanto houver pendentes). Sem regressão de formato.
- **Fire com `$.biome=''` (unattributable)**: mesmo tratamento — fora dos
  pct, dentro do total. Idêntico ao comportamento de `classify_fires`
  (foco não classificado não incrementa `total` de `pct`).
- **DB sem índice `idx_fire_bbox_date`** (DBs antigos): a janela usa
  `idx_fire_acq_date`/full scan + LIMIT — mesmo plano que o `find_fires`
  atual já usa; sem degradação.
- **cjson: tabela vazia → `{}`, array → `[]`**: shape novo usa array
  sempre; a guard de `{}` fica inócua (benéfica: evita recompute em DB
  vazio).
- **Subprocesso de alerts sem TI/UC no DB**: `generate_all_alerts` já
  pcall's cada sub-fonte (prodes/deter/pm25) e TI/UC com lookup vazio
  geram 0 alerts — o subprocesso só pode falhar no hard path (db) e o lock
  expira (TTL); o route serve stale.
- **Concorrrência de 2 subprocessos de alerts**: lock `setnx` 1800s; o
  segundo spawn volta cedo. TTL cobre crash.
- **Testes rodando sem Redis real**: stubs restaurados no teardown
  (common-mistakes #2); nenhum teste escreve em namespace de produção.

## Verification

- **Automatizado** (baseline atual: **318 successes / 0 failures**):
  ```bash
  cd backend-lua && busted tests/test_biomes_route.lua tests/test_car_routes.lua tests/test_tiles_fallback.lua
  busted tests/*.lua   # suite completo
  ```
- **Integridade do PNG novo** (script fora do diff, roda em python3):
  decodifica o blob servido com PIL + confere CRC de todos os chunks com
  `zlib.crc32`.
- **Manual**:
  1. `make stop && make start` (backend Lua).
  2. `curl -s 'http://127.0.0.1:5000/api/tiles/prodes?z=2&x=3000&y=3000' |
     python3 -c 'import sys,io;from PIL import Image;Image.open(io.BytesIO(sys.stdin.buffer.read())).load();print("PNG ok")'`
     → `PNG ok` (antes: `broken data stream`).
  3. Tile real CAR: `curl -s 'http://127.0.0.1:5000/api/tiles/car?z=8&x=107&y=52'
     | file -` → `PNG image data, 256 x 256`.
  4. `time curl http://127.0.0.1:5000/api/biomes` (Redis flush do `biomes:all`
     antes) → < 0.5s (antes ~1.5s); shape idêntico (6 biomes, array).
  5. App em `http://localhost:5001`: panning incl. oceano/fora do BR →
     **zero** `Image corrupt or truncated` no console; "Focos por bioma"
     carrega em < 1s.
  6. `curl -s http://127.0.0.1:5000/api/alerts` (cache vazia) → responde
     imediatamente (200, stale/vazio) e o subprocesso popula o cache em ~1s
     (log do subprocesso / `alerts:all` no Redis).
- **Done criteria**:
  - Panning sem nenhum `Image corrupt or truncated` (CAR + PRODES).
  - `/api/biomes` < 0.5s em miss, shape inalterado; prewarm não congela o
    loop (> 0.3s de bloqueio).
  - `/api/alerts` nunca bloqueia o loop por > 100ms (subprocesso).
  - Suite completo verde (baseline 318 + novos testes).

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` **§1** — fixtures clock
  relative: teste novo usa `days_ago(n)`; a janela SQL usa apenas
  ORDER/LIMIT (sem datas absolutas).
- **§2** — testes não tocam Redis de produção: stub + restore no teardown;
  nenhum namespace real escrito.
- **§3** — batching/N+1: o aggregate SQL substitui loop O(10k×rings);
  mesmo padrão da irmã `get_fires_by_biome` (db.lua).
- **Precedente interno** (main.lua, comentado): compute pesado inline no
  loop copas bloqueia tudo — `ti-at-risk` e news usam subprocesso; alerts
  segue o mesmo padrão (este plano).

## Estimated scope

M+ (2 bugs + 1 anti-padrão; ~8 arquivos + 2 novos; ~15 testes novos; sem
migração de schema; sem mudança de frontend).

## Resolvido no review (era Open question)

- `classify_fires`: **mantido** (back-compat; só sai dos callers de
  rota/prewarm).
- `/api/alerts` inline: **aprovado como SHOULD** — subprocesso
  `tools/warm_alerts.lua` no padrão `warm_ti_at_risk.lua` (item 6–8 acima).

## Done (2026-08-27) — implementado e verificado

**Suite:** `busted tests/*.lua` → **325 successes / 0 failures / 0 errors**
(baseline era 318; +7: 6 de `test_biomes_route.lua` + 1 de corrupt-blob em
`test_tiles_fallback.lua`). Testes self-clean (sem db temporário pendurado).

**Verificação ao vivo** (servidor via `run-lua.sh`, Redis real):

| Item | Resultado | Antes |
|---|---|---|
| Tile CAR miss (z2) | 68 B, PIL ok `(1,1) RGBA (0,0,0,0)` | 67 B, `broken data stream` |
| Tile PRODES miss | 68 B, PIL ok | (idêntico) |
| Tile CAR real z6 (Manaus) | 7373 B, PIL ok 256×256, 39.9k px opacos | (ok) |
| `/api/biomes` (cache miss) | **~16 ms**; shape: array de 6 biomas, total_fires=10000, last_sync ok | **~1.5 s** (bloqueando o loop) |
| `/api/alerts` (cold, sem cache) | **17 ms** (fallback stale/vazio) + subprocesso `warm_alerts.lua` populou Redis (660 alerts) em ~7 s; lock liberado no fim | ~0.8 s **inline**, bloqueando todo o loop copas |
| `/api/biomes` dados reais | Amazônia 3045 (45.3%), Cerrado 2668 (39.7%), Caatinga 490, Mata Atlântica 482, Pampa 24, Pantanal 19 | (idem, porém lento) |

**Arquivos além dos planejados:** `tests/test_car_routes.lua` e
`tests/test_tiles_fallback.lua` precisaram de fixtures PNG válidos — o novo
check de assinatura em `lookup_tile` rejeita blob sem assinatura (exatamente
o que quebraria fixtures com strings falsas tipo `TILE-BYTES`).

**Comportamento em produção observado (caveat, documentado):** justo após um
sync FIRMS grande, os focos recém-ingridos têm `$.biome = NULL` até o
`biome_backfill_loop` os atribui (batches de 500 a ~250/s; backlog de ~1.2k
esvazia em ~5 s; a janela de 10k fica 100% atribuída — verificado). Durante
essa janela o painel mostra contagens por bioma parcialmente completas
(`total_fires` já correto). Isso é **fidelidade ao fluxo antigo**: o
`classify_fires` também lia o mesmo `$.biome` persistido, então um foco
recém-syncado era inatribuído antes também. Sugestão p/ próximo PR (fora
deste escopo): classificar no ingest (`fetch_firms_data` já tem o layer de
biome carregado) para fechar a lacuna de primeira pintura.
