# Sinaflor — Fogo Permitido (ASV/AUTESP via CKAN Ibama → hook → scp prod)

## Context

A Yvy classifica a natureza de cada foco FIRMS em `{crime, suspeito, permitido,
natural}` (`.plans/fire-nature-classify`), mas **"permitido" é inalcançável hoje**:
o hook `sinaflor` em `fire_classify.lua` é `nil`, então todo foco em CAR fora da
moratória cai em `suspeito`. Este plano fornece a **primeira fonte real de
autorizações** e fecha o gap:

1. Baixa localmente as autorizações nacionais do Ibama (**ASV** — Autorização de
   Supressão de Vegetação — e **AUTESP** — Autorização Especial) do portal de
   dados abertos `dadosabertos.ibama.gov.br` (CKAN), **não** do painel Sinaflor
   (que exige login SSO gov.br e não é scriptável — verificado em 2026-08-08).
2. Ingere num **DB SQLite dedicado** (`sinaflor_auth.db`, padrão `car.db`), com
   o código CAR resolvido offline (CAR code do dataset quando existe; fallback
   espacial lat/lon→polígono CAR).
3. Liga o **hook `sinaflor`** em `tools/classify_fires.lua`, fazendo focos em
   CAR com autorização ASV/AUTESP vigente na data virarem **`permitido`**.
4. Sincroniza o DB para produção via **scp** e dispara a reclassificação.

Restrição central herdada do plano pai: o backend é um loop copas
single-threaded — **nenhum cruzamento espacial denso no loop**. Todo
cruzamento espacial (lat/lon da autorização → polígono CAR) acontece **offline
no import**; o runtime é um lookup indexado por `cod_imovel + data`.

## Assumptions and decisions

- Decision: fonte = **CKAN Ibama (`dadosabertos.ibama.gov.br`), datasets ASV +
  AUTESP**, downloads diretos dos recursos CSV (blob Azure), atualização
  semanal. User-confirmed (proxy de "Permitido" aceito; não existe dataset de
  "Queima Controlada" no Ibama open data — `package_search?q=queima` → 0).
- Decision: janela = autorizações com `DATA_DE_VALIDADE >= hoje - 2 anos`
  (vigentes + 2 anos de histórico). User-confirmed.
- Decision: junção = **CAR code do dataset quando existe + fallback espacial
  offline** (lat/lon da autorização → CAR via `car_rtree`/shapely STRtree),
  gravando `cod_imovel` resolvido. User-confirmed.
- Decision: armazenamento em **DB dedicado** `backend-lua/data/sinaflor/
  sinaflor_auth.db` (nunca toca o `yvy.db` vivo) — torna o scp→prod seguro e
  atômico. Source: padrão `car.db` @ `app/car_import.lua`, `app/lookups/
  car_lookup.lua:23-28`.
- Decision: hook injetado em `classify_fires.lua:58` via 3º argumento `cfg`
  (`fire_classify.classify_fire(fire, territory, cfg)`), com lookup module
  `app/lookups/sinaflor_lookup.lua` pré-carregando as janelas em memória
  (mapa `cod_imovel → [{inicio, fim, nro, modo}]`). Source: código @
  `classify_fires.lua:41-83`, `fire_classify.lua:38,168-175`.
- Decision: `evidence.authorization` passa a guardar o objeto da autorização
  (nro, modo, datas) em vez de `true` — popup mostra o nº e o tipo. Mudança
  mínima em `fire_classify.lua:174` (truthy aceita bool ou tabela).
- Decision: **bump `FIRE_NATURE_VERSION` 2 → 3** no default do código
  (`fire_classify.lua:31`), no `.env.example` e no env de prod, para
  reclassificar focos existentes (`nature_version < 3`). Source:
  `fire_classify.lua:31`, `tools/classify_fires.lua` (arg `version`).
- Decision: **normalização da chave CAR**: `cod_imovel` em UPPERCASE, sem
  strip, em ambos os lados (coluna `NRO_CAR_IMOVEL_RURAL` do dataset e
  `car_data.cod_imovel` do SICAR) — os dois lados precisam concordar na junção
  explícita E no fallback espacial. Source: `car_lookup.lua:136-143`.
- Decision: **`DATA_DE_VALIDADE` vazia** → `data_fim` aberta (`9999-12-31`);
  `DATA_DE_EMISSAO` vazia → linha descartada no import (sem janela definível).
- Decision: script de download em **Python** (`scripts/data/download_sinaflor_auth.py`),
  reutilizando `requests`/`shapely`/`pandas` (já em `scripts/requirements.txt`)
  e o padrão de escrita `sqlite3` de `scripts/data/cross_deter_car.py`.
- Decision: deploy via `scripts/deploy/sync-sinaflor.sh` (scp do DB + trigger de
  reclassificação no prod via `/api/admin/fires/classify`). User pediu
  "ingestão local → subir via scp".
- Assumption: datasets ASV/AUTESP podem ou não conter `NRO_CAR_IMOVEL_RURAL`;
  o schema real é descoberto no runtime (CKAN `package_show` + inspeção do CSV
  baixado) — ver common-mistake #4. **Confirmado: AUTESP não tem o campo** (só
  ASV, a confirmar no Inc 1). Se uma autorização não tiver CAR code nem
  coordenadas válidas, é descartada com contagem logada.
- Assumption: datas chegam em `DD/MM/AA` (2 dígitos, ano com pivot: 00–69 → 20xx,
  70–99 → 19xx) e coordenadas em texto — normalizadas para `YYYY-MM-DD` /
  `REAL` no import.

## Files to touch

### scripts/data/download_sinaflor_auth.py (NEW)

- What changes: download + normalize + resolve CAR + grava `sinaflor_auth.db`.
- Usage:
  ```
  python3 scripts/data/download_sinaflor_auth.py                # default: 2 anos (730d), todos UFs
  python3 scripts/data/download_sinaflor_auth.py --window 365   # 1 ano (uso explícito)
  python3 scripts/data/download_sinaflor_auth.py --today 2026-08-08  # override do relógio (testes)
  python3 scripts/data/download_sinaflor_auth.py --force        # re-download mesmo com DB recente
  python3 scripts/data/download_sinaflor_auth.py --ufs MT PA    # filtro por UF
  python3 scripts/data/download_sinaflor_auth.py --no-car-resolve
  python3 scripts/data/download_sinaflor_auth.py --out backend-lua/data/sinaflor/sinaflor_auth.db
  ```
- Functions:
  - `ckan_package_list() -> list[str]` — `package_list` (descobre IDs no
    runtime; não hardcoda).
  - `ckan_resource_url(package_id) -> str` — `package_show` → primeiro recurso
    `format=CSV` nacional. Falha alto se o recurso esperado (ASV/AUTESP) sumir.
  - `download_csv(url, dest) -> Path` — `requests.get` com `User-Agent` Yvy,
    streaming, retry com backoff (padrão `download_deter_wfs.py`). **Detecta
    recurso em ZIP** (extensão `.zip` ou `content-type: application/zip`, como o
    AUTESP `SimplificadoAUTESP_csv.zip`) e extrai o CSV interno com `zipfile` —
    ASV é `.csv` puro, AUTESP é zip; nunca assumir formato único.
  - `normalize(df) -> DataFrame` — mapeia colunas → `nro_autorizacao, modo,
    data_inicio, data_fim, uf, municipio, situacao, lat, lon, nro_car`.
  - `resolve_car(df, car_db_path) -> DataFrame` — preenche `cod_imovel`:
    coluna `nro_car` quando presente; senão `shapely.STRtree` sobre
    `car_rtree` (padrão `cross_deter_car.py`). **AUTESP não tem
    `NRO_CAR_IMOVEL_RURAL` (dicionário CKAN confirmado) → o fallback espacial é
    o caminho PRIMÁRIO dela, não exceção; sem `car.db` as linhas AUTESP ficam
    sem `cod_imovel` e são descartadas com contagem.**
  - `write_db(df, out_path) -> int` — schema + batch insert (1000) +
    `wal_checkpoint(TRUNCATE)` + VACUUM; aceita `--today` para a janela de 2
    anos ser determinística em teste (filtro `DATA_DE_VALIDADE >= today-730d`).
    **Grava em `<out>.tmp` e faz `os.replace` atômico** (DB dedicado substituído
    por inteiro — padrão de troca do `car.db` sob leitor `query_only=ON`), em
    vez de TRUNCATE in-place + restore; só depois escreve o marker de sucesso.
- Data shapes: entrada CSV (blob Azure) → linhas normalizadas
  `{nro_autorizacao, modo, data_inicio, data_fim, uf, municipio, situacao,
  lat, lon, cod_imovel}` (`data_fim` vazio → `9999-12-31`); saída SQLite
  escalar (sem JSONB — ver schema abaixo).
- Integration points: chamado manualmente ou por `sync-sinaflor.sh`;
  consome `car.db` (só leitura, `file:...?mode=ro`) para o fallback espacial.
- Error paths: CKAN fora/404 → aborta (exit≠0) sem escrever marker (ver
  common-mistake #5); recurso ASV/AUTESP ausente → erro explícito; linha sem
  CAR e sem coordenadas → descarta com contagem; `car.db` ausente → grava só
  `nro_car` explícito (ASV que tiver CAR) e loga aviso de que **AUTESP inteiro
  fica sem `cod_imovel`**; `DATA_DE_EMISSAO` vazia → linha descartada.

### backend-lua/app/lookups/sinaflor_lookup.lua (NEW)

- What changes: carrega as autorizações em memória; expõe o hook.
- Functions:
  ```lua
  _M.db_path()                                   -- env SINAFLOR_DB_PATH → fallbacks locais → /opt/yvy/backend-lua/data/sinaflor/sinaflor_auth.db (padrão car_lookup.lua:15-21)
  _M.load_sinaflor()                             -- abre handle ro + PRAGMA query_only=ON (sobrevive à troca do arquivo por scp/importer, padrão car_lookup.lua); memo is_loaded
  _M.is_loaded() -> bool                         -- memo 60s TTL (padrão car_lookup.lua:196)
  _M.count() -> int
  _M.authorized(car_prop, acq_date) -> {nro, modo, data_inicio, data_fim} | nil
  _M.hook() -> fn(car_prop, acq_date) -> auth|false  -- envolve authorized(); devolve o OBJETO (não bool) p/ evidence.authorization carregar nro/modo
  ```
- Data shapes: **`car_prop` é o objeto `territory.car` = `{id, name, uf}`**
  (retorno de `car.classify_point`, `car_lookup.lua:266-270`) — **nunca uma
  string**. O lookup usa `tostring(car_prop.id):upper()` como chave no mapa
  `cod_imovel -> { {inicio, fim, nro, modo}, ... }` (normalização UPPERCASE
  concordante com a junção explícita e com o fallback espacial).
  `authorized` compara `acq_date` (string `YYYY-MM-DD`, lexicográfica) contra
  cada janela `[inicio, fim]`; com várias autorizações ativas na data, retorna
  a de `data_inicio` mais recente (determinístico).
- Integration points: usado por `tools/classify_fires.lua` (e testes).
- Error paths: DB ausente/corrompido → `load_sinaflor` não derruba (pcall no
  chamador), hook retorna `false` (comportamento atual de "sem dado → não
  autorizado").

### backend-lua/tools/classify_fires.lua (EDIT)

- What changes: carrega o lookup e passa o hook no 3º arg.
- Functions: no bootstrap, após `car` (linha ~29):
  ```lua
  local sinaflor = nil
  pcall(function() sinaflor = require("app.lookups.sinaflor_lookup") end)
  if sinaflor and sinaflor.load_sinaflor then pcall(sinaflor.load_sinaflor) end
  ```
  E na linha 58:
  ```lua
  local cfg = sinaflor and { sinaflor = sinaflor.hook() } or nil
  local res = fire_classify.classify_fire(row, territory, cfg)
  ```
- Error paths: `sinaflor` nil (DB ausente) → mesmo comportamento de hoje
  (nil-safe); a chamada do hook dentro do loop é envolta em `pcall` (falha →
  `false`), para uma linha malformada não derrubar o batch inteiro
  (common-mistake #3).

### backend-lua/app/fire_classify.lua (EDIT, mínima)

- What changes: `evidence.authorization = auth` (objeto) em vez de `true`
  (linha ~174), para o popup/dashboard mostrarem nº/modo; default do
  `NATURE_VERSION` (linha 31) sobe de `"2"` para `"3"`.
- Data shapes: `evidence.authorization = {nro=..., modo=..., data_inicio=...,
  data_fim=...} | true`.
- Integration points: chamadores atuais são nil-safe a tabela.

### backend-lua/app/db.lua (EDIT)

- What changes: projeta `nature_evidence` no retorno de `find_fires`/
  `rows_to_fires` (decodificado via `json(nature_evidence)`), para o
  `/api/fires` expor a autorização. Hoje o select só traz
  `lat, lon, acq_date, ingested_at, nature, nature_at, data`.
- Data shapes: `rows_to_fires` → `{..., nature, nature_evidence =
  {authorization = {nro, modo, data_inicio, data_fim}} | nil, nature_version}`.
- Error paths: `nature_evidence` NULL → `nil` (nil-safe).

### frontend/src/components/Home.js (EDIT, mínimo)

- What changes: `FirePopupContent` mostra, quando `fire.nature_evidence.authorization`
  existe, a linha "Autorização: <nro> (<modo>)" na cor do permitido.
- Integration points: já renderiza `fire.nature`; adiciona o campo de evidência
  (nil-safe).

### backend-lua/tests/test_fire_classify.lua (EDIT)

- Add: caso com stub `sinaflor = function() return {nro="AUT", modo="ASV",
  data_inicio="2026-01-01", data_fim="2026-12-31"} end` → `evidence.authorization`
  carrega o objeto (e `true` continua aceito, compat).

### .env.example (EDIT)

- Add: `FIRE_NATURE_VERSION=3` e `SINAFLOR_DB_PATH=` (vazio → default).

### scripts/deploy/sync-sinaflor.sh (NEW)

- What changes: (re)gera DB local se ausente → scp → trigger reclassify no prod.
- Usage: `bash scripts/deploy/sync-sinaflor.sh [--vm-ip IP] [--dry-run]`
- Flow:
  1. `python3 scripts/data/download_sinaflor_auth.py` — re-baixa se o DB local
     tiver mais de 7 dias OU `--force` (refresh semanal real, não só na 1ª vez).
  2. `scp -i ~/.ssh/oci_yvy backend-lua/data/sinaflor/sinaflor_auth.db
     ubuntu@$VM_IP:/opt/yvy/backend-lua/data/sinaflor/` (cria dir remoto).
  3. Reclassificação com **versão monotônica**: lê/incrementa
     `/opt/yvy/backend-lua/data/sinaflor/.sync_version` no prod e passa
     `?version=N` **na query string** — a rota `POST /api/admin/fires/classify`
     só lê `ctx.req.args.version` (query; o body não é mergeado em `args`,
     `main.lua:167` / `server.lua:102-110`). Sem versão monotônica a
     reclassificação semanal seria no-op (`nature_version < N` não reavalia
     `suspeito` antigos que ganharam autorização nova):
     `curl -X POST -H "X-API-Key: $API_KEY"
     "http://$VM_IP:5000/api/admin/fires/classify?version=N"` (lock Redis
     `fires:classify:lock` evita corrida; subprocesso destacado).
  4. Verifica: `curl http://$VM_IP:5000/api/fires/nature-stats` → `classes.permitido`.
- Error paths: VM_IP ausente → lê de `.env`/arg; SSH key ausente → erro com
  instrução (padrão `deploy-local.sh`); reclassify falha → loga, DB já está no
  prod (idempotente, re-run seguro).

### .github/workflows/ci.yml (EDIT)

- What changes: adiciona `scripts/deploy/sync-sinaflor.sh` à **lista explícita**
  do job `shell-check` (o CI não usa glob — `ci.yml:52-63`); sem isso o novo
  `.sh` nunca passa por `sh -n` no CI. O novo `.lua` (lookup) e `tests/*.lua`
  já são cobertos automaticamente (`find backend-lua -name '*.lua'` + `busted
  tests/*.lua`); o projeto não tem job Python — o novo `.py` fica consistente
  com os demais `scripts/data/*.py` (só `py_compile` local).

### backend-lua/tests/test_sinaflor_lookup.lua (NEW)

- What changes: busted com fixtures de DB temporário (`env.set("SQLITE_PATH"...)`
  não se aplica — lookup usa `SINAFLOR_DB_PATH`; usar `env.set("SINAFLOR_DB_PATH", tmp)` +
  `package.loaded["app.lookups.sinaflor_lookup"]=nil` re-require, padrão
  `tests/test_db.lua:5-20`).
- Tests: `authorized` dentro/fora da janela; CAR sem autorização → nil; CAR com
  múltiplas janelas → acha a ativa; `count()`/`is_loaded()`; hook() retorna
  fn; DB ausente → não derruba.

### AGENTS.md (EDIT)

- What changes: seção curta documentando a fonte (CKAN Ibama, ASV+AUTESP,
  semanal), o DB dedicado, o fluxo `download → ingest → scp → reclassify`, e a
  chave `SINAFLOR_DB_PATH`.

### Makefile (EDIT, opcional)

- What changes: targets `ingest-sinaflor` e `sync-sinaflor` espelhando
  `sync-sinaflor.sh`.

## Edge cases

- **Autorização sem CAR code e sem coordenadas válidas**: descartada no import,
  contagem logada (nunca crash).
- **Datas `DD/MM/AA`**: pivot de ano; `data_inicio` = `DATA_DE_EMISSAO`,
  `data_fim` = `DATA_DE_VALIDADE` (a janela [emissão, validade] é o período em
  que a atividade é autorizada).
- **Situação cancelada/vencida**: default inclui tudo com `data_fim >=
  hoje-2anos`; se o domínio real de `SITUACAO` revelar valores de cancelamento,
  filtrar no Inc 1 (inspecionar o CSV baixado — common-mistake #4).
- **`DATA_DE_VALIDADE` vazia** → `data_fim` aberta (`9999-12-31`); emissão vazia
  → descartada.
- **Várias autorizações ativas na data do foco** → retorna a de `data_inicio`
  mais recente (determinístico) para o `nro` da evidência.
- **Foco na moratória**: não chega ao hook (fire_classify só chama `sinaflor`
  fora da moratória) — sem mudança.
- **DB `sinaflor_auth.db` ausente em prod**: hook nil-safe → comportamento
  atual (suspeito), nunca quebra.
- **Volume nacional**: CSV pode ser grande — streaming + batch 1000 + VACUUM.
- **Re-run idempotente**: import grava `<out>.tmp` e faz `os.replace` atômico
  (substitui o arquivo inteiro; sem TRUNCATE in-place no arquivo vivo) e só
  então escreve o marker de sucesso — falha a qualquer momento deixa o DB
  anterior intacto (common-mistake #5 aplicado de forma atômica).
- **Coordenada inválida** (`lat=""`, `"36.5.5"`): `parse_float` → `None`,
  linha vai para o caminho "sem coordenadas" (descartada se também sem CAR).
- **Recurso CSV em ZIP (AUTESP)**: `download_csv` detecta `.zip`/`content-type`
  e extrai o CSV interno (`zipfile`) — ASV é `.csv` puro; nunca assumir formato único.

## Verification

- Run:
  - `python3 scripts/data/download_sinaflor_auth.py --window 730` local → cria
    `backend-lua/data/sinaflor/sinaflor_auth.db` com contagem > 0.
  - `sqlite3 backend-lua/data/sinaflor/sinaflor_auth.db 'SELECT modo, count(*) FROM sinaflor_auth GROUP BY modo;'`
  - `make test-lua` (busted) verde.
  - `luac -p backend-lua/app/lookups/sinaflor_lookup.lua backend-lua/tools/classify_fires.lua backend-lua/app/fire_classify.lua`
  - `bash -n scripts/deploy/sync-sinaflor.sh`; `python3 -m py_compile scripts/data/download_sinaflor_auth.py`.
- Tests to add/update: `test_sinaflor_lookup.lua` (acima); `test_fire_classify.lua`
  ganha caso de `evidence.authorization` com objeto (o stub atual `:93` continua
  verde — tabela é truthy); script Python com `--today` para a janela de 2 anos
  ser determinística.
- Manual:
  - Local: `FIRE_NATURE_VERSION=3 lua5.1 backend-lua/tools/classify_fires.lua 3`;
    `curl localhost:5000/api/fires?days=30 | jq '[.[] | select(.nature=="permitido")] | length'`.
  - Prod: `bash scripts/deploy/sync-sinaflor.sh --dry-run`, depois real;
    conferir `classes.permitido` em `/api/fires/nature-stats`.
- Done criteria: focos em CAR com ASV/AUTESP vigente, fora da moratória,
  aparecem **verdes (Permitido)** no mapa em `http://localhost:5001` e em prod
  após o scp.

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md`
  - **#4 (pin ao schema vivo)**: descobrir pacotes/recursos via CKAN API e
    inspecionar o CSV baixado antes de confiar em colunas (`NRO_CAR_IMOVEL_RURAL`
    pode não existir em ASV/AUTESP).
  - **#3 (N+1 é smell)**: lookup em memória pré-carregado, nunca query por foco.
  - **#5 (marker-after-success)**: import com backup + marker; restore
    table-level em falha pós-truncate.
  - **#1 (fixtures clock-relative)**: testes do lookup usam janelas fixas
    (autorização não é windowed por "hoje") — OK manter datas absolutas; o
    filtro de 2 anos é do script, tornado determinístico via `--today`.
  - **#6 (pandas Series `or`)**: checks de coluna com `in df.columns`, nunca
    `or` sobre Series; áreas/coordenadas tratadas como float.

## Estimated scope

M (8 arquivos novos/editados; fonte nacional via CKAN; um PR coeso — download,
import, hook, deploy, testes, docs).

## Open questions (CONSIDER from review)

- **Custo da reclassificação semanal com versão monotônica**: cada sync
  reclassifica todos os focos com `nature_version < N` (≈ recompute completo em
  subprocesso destacado). Se exceder ~1h na VM de 1GB, adicionar um caminho
  incremental por janela de dias (ex: `acq_date >= now-30d`) como follow-up.
- **Escolha entre autorizações sobrepostas**: definida como `data_inicio` mais
  recente; revisar se a semântica desejada for "janela mais longa que contém a
  data".
- **Filtro de 2 anos vive no Python** (é `today`-relativo): testado via
  `--today`; alternativa futura é mover o corte para a query de carga.

## Status — implementado em 2026-08-08 (via /implement-plan)

Todos os increments concluídos e verificados localmente; PR único coeso.

**Schema real descoberto no Inc 1 (common-mistake #4) — divergências do plano:
- Separador é `;` em AMBOS os datasets (não `,`); detectado em runtime
  (`detect_sep`), nunca assumido.
- Datas: AUTESP é ISO `YYYY-MM-DD`; ASV é `DD/MM/YYYY` (4 dígitos). O parser
  cobre ISO + DD/MM/YYYY + DD/MM/AA (pivot 00-69→20xx) — mais amplo que a
  premissa original de só DD/MM/AA.
- Coordenadas: AUTESP usa ponto decimal; ASV usa vírgula decimal
  (`-15,504482`). `parse_float` normaliza vírgula→ponto.
- `NRO_CAR_IMOVEL_RURAL` existe SÓ no ASV (16,4% das linhas; formato SICAR
  43-char confirmado); AUTESP não tem → fallback espacial é o caminho primário
  dele (confirmado).
- `SITUACAO` existe nos dois e o domínio revelou cancelamento: `Cancelada`
  (5346) + `Suspensa` (431) são FILTRADAS no import; `Vencida` é mantida (a
  janela de 2 anos em `data_fim` já a limita). `Emitida`/`Retificada`/`Renovada`
  mantidas.
- ASV é `.csv` puro com BOM (content-type `application/octet-stream` — não dá
  p/ confiar no content-type); AUTESP é ZIP real. `download_csv` detecta ZIP por
  magic bytes (`PK\x03\x04`), nunca por extensão/content-type.

**Resultados da verificação local:**
- `download_sinaflor_auth.py --window 730` → `sinaflor_auth.db` com **11.193
  linhas** (ASV 10.356 + AUTESP 837; 8.179 imóveis distintos; resolução CAR:
  2.850 explícitos + 8.343 espaciais; 7.449 sem CAR descartadas com contagem).
  `--today 2026-01-01` → min `data_fim` = `2024-01-02` (janela determinística).
- `busted tests/*.lua` → **231 sucessos / 0 falhas** (test_sinaflor_lookup.lua
  novo + test_fire_classify.lua estendido, NATURE_VERSION 2→3).
- `luac -p` nos 4 .lua alterados/novos; `py_compile` no .py; `bash -n` +
  `--dry-run` no sync-sinaflor.sh — todos verdes.
- Backfill real local `FIRE_NATURE_VERSION=3 tools/classify_fires.lua 3` →
  166.152 focos em 110s: **`permitido` = 2.035** (antes 0); `evidence.authorization`
  = `{modo, nro, data_inicio, data_fim}` gravado em JSONB.
- `/api/fires` (bbox) retorna `nature_evidence.authorization` + `nature_version`
  (projeção nova em db.lua via `json(nature_evidence)`); `/api/fires/nature-stats`
  mostra `classes.permitido = 2035`. Moratória jul-out → focos recentes são crime
  (correto: o hook só é consultado fora da moratória).
- `npm run build` frontend OK (Home.js mostra "Autorização: <nro> (<modo>)" na
  cor do permitido; chaves i18n pt/en).

**Pendente (manual, prod):** `bash scripts/deploy/sync-sinaflor.sh --dry-run`
depois real (scp → `?version=N` monotônico → conferir `classes.permitido`).
