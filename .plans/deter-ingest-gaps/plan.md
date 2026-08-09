# DETER Ingestion Gaps Analysis

## Context

O dashboard `/api/dashboard/freshness` reporta `deter` e `deter_car` como `available: false` (0 rows).
As tabelas `deter_polygons`, `deter_alerts`, e `deter_car_alerts` estão vazias.
Os scripts de ingestão existem mas nunca rodaram (ou falharam silenciosamente).

**Problema:** Sem dados DETER, o sistema não consegue:
- Mostrar polígonos de desmatamento recente no mapa
- Alertar sobre DETER em propriedades CAR
- Calcular severidade de alertas CAR com base em DETER
- Reportar métricas de desmatamento no dashboard

## Assumptions and decisions

- **Decision:** Scripts de ingestão já existem (`download_deter_wfs.py`, `backfill_deter_alerts.py`, `cross_deter_car.py`, `deter_daily.sh`) — **Source:** code @ `scripts/data/`
- **Assumption:** TerraBrasilis WFS está acessível em `https://terrabrasilis.dpi.inpe.br/geoserver/deter-amz/ows` — **Source:** code @ `scripts/data/download_deter_wfs.py:20`
- **Assumption:** CAR database existe em `backend-lua/data/car/car.db` — **Source:** code @ `scripts/data/cross_deter_car.py:52`
- **Decision:** Pipeline diário roda via `deter_daily.sh` mas não está agendado (systemd/cron) — **Source:** code @ `scripts/data/deter_daily.sh`
- **Assumption (corrigido na review):** Não há `.venv/` neste workspace (exFAT não
  suporta symlinks). Instalar `geopandas` no `python3` do sistema via `pip
  install --user --break-system-packages` (PEP 668).
- **Assumption (corrigido durante implementação):** TerraBrasilis WFS
  `GetFeature` pode retornar **HTTP 200 com XML `ows:ExceptionReport`** quando o
  GeoServer está com erro de pool ("Timeout waiting for idle object"). O script
  agora detecta isso e retry com backoff (5s → 80s total) em vez de falhar com
  `JSONDecodeError`.
- **Decision:** Ingestão inicial deve ser backfill + incremental (não apenas --days 1)
- **Decision:** `deter_car_alerts` só fica `available: true` se CAR DB existe — se ausente, `deter_car.available: false` é **esperado** (não é bug)

## Files to touch

> **Conclusão da review:** **nenhum código precisa mudar.** Todos os scripts de
> ingestão e os endpoints já estão implementados e corretos. O trabalho é
> operacional: executar o backfill + garantir o agendamento. (O "logging extra"
> proposto no rascunho original era desnecessário — os scripts já printam
> contagens em formato greppable.)

### scripts/data/download_deter_wfs.py
- **What changes:** Adicionar detecção de `ows:ExceptionReport` (erro de pool do
  GeoServer) e retry com backoff maior no `fetch_page()`.
- **Function(s):** `fetch_page()` @ `scripts/data/download_deter_wfs.py:48`,
  `_is_exception_report()` helper.
- **Data shapes:** Nenhuma mudança de schema.
- **Integration points:** Chamado por `deter_daily.sh`; consumido pelo rollup em
  `backfill_deter_alerts.py`.
- **Error paths:**
  - GeoServer pool overload → 5 retries com backoff 5/10/20/40s.
  - Outro `ExceptionReport` (ex: `InvalidParameterValue`) → retry não resolve;
    ainda assim é melhor logar o XML ao invés de `JSONDecodeError`.
  - Resposta 200 não-JSON e não-XML → cai no `ValueError` existente.

### scripts/data/deter_daily.sh
- **What changes:** **Nenhuma mudança de código** — já faz download → rollup → cross
  → DETER×UC/TI com `set -eu` e fallback de interpretador.
- **Integration points:** systemd timer `yvy-deter-daily.{service,timer}.j2` já
  existem em `ansible/templates/` (`OnCalendar=*-*-* 04:30:00`).
- **Ação:** apenas garantir que o timer está habilitado após o deploy.

### backend-lua/app/routes/dashboard.lua
- **What changes:** **Nenhuma mudança necessária** — endpoint `/api/dashboard/freshness` já suporta `deter` e `deter_car`
- **Function(s):** `_M.get_freshness(ctx)` @ `backend-lua/app/routes/dashboard.lua:118`
- **Data shapes:** Retorna `{sources: [{id, rows, last_ingested_at, available}], coverage: {state_pct, biome_pct, nature_pct}}`
- **Integration points:** Lê `db.get_ingest_freshness()` @ `backend-lua/app/db.lua:972`

### backend-lua/app/db.lua
- **What changes:** **Nenhuma mudança necessária** — `get_ingest_freshness()` já consulta `deter_polygons` e `deter_car_alerts`
- **Function(s):** `_M.get_ingest_freshness()` @ `backend-lua/app/db.lua:972`
- **Data shapes:** Retorna `{firms: {rows, last_ingested_at}, news: {...}, deter: {...}, deter_car: {...}}`

### .github/workflows/ci.yml (opcional)
- **What changes:** **S3:** adicionar apenas `py_compile` (syntax) dos 3 scripts DETER — sem rede
- **Integration points:** Job atual só faz syntax check Lua/C; `py_compile` é aditivo e offline

## Edge cases

- **DETER WFS indisponível:** Script deve falhar explicitamente (não silently skip)
- **CAR DB ausente:** `cross_deter_car.py` aborta com erro claro → `deter_daily.sh` torna este step opcional; `deter_car.available: false` é esperado
- **Shapely versão errada:** `cross_deter_car.py` já valida shapely 2.x @ `scripts/data/cross_deter_car.py:36`
- **GeoServer retorna FeatureCollection vazio:** Normal (sem dados novos), não é erro
- **Polygonos sem geometria:** `download_deter_wfs.py` já filtra `geom IS NOT NULL` @ `scripts/data/download_deter_wfs.py:112`
- **Área ausente:** `download_deter_wfs.py` já fallback para `areauckm + areamunkm` ou NULL @ `scripts/data/download_deter_wfs.py:79`
- **Geometria inválida:** skip feature + warning → não aborta pipeline (DETER é diário, dados novos chegam amanhã)

## Verification

### Step 0 — Root cause diagnosis

Antes de rodar a ingestão, diagnosticar por que os dados estão vazios.
**M1:** não há `.venv/` neste workspace — resolver `PY` como faz `deter_daily.sh`
(`[ -x .venv/bin/python3 ]` senão `python3` do sistema, que já tem `shapely 2.1.2`).

```bash
cd /media/smk/Shared/Code/Yvy
# Resolução de interpretador (mesma lógica de scripts/data/deter_daily.sh)
if [ -x .venv/bin/python3 ]; then PY=.venv/bin/python3; else PY=python3; fi
echo "Using PY=$PY"

# 1. Check deps (shapely 2.x + geopandas)
"$PY" -c "import shapely, geopandas; print('deps OK — shapely', shapely.__version__)" || \
  echo "FAIL: missing deps — install scripts/requirements.txt (shapely>=2, geopandas)"

# 2. Check CAR DB exists (required for deter_car_alerts)
if [ -f backend-lua/data/car/car.db ]; then
  echo "CAR DB OK: $(ls -lh backend-lua/data/car/car.db)"
else
  echo "WARN: CAR DB not found — deter_car_alerts will remain empty (expected)"
fi

# 3. Check systemd timer enabled (if deployed)
if command -v systemctl >/dev/null 2>&1; then
  systemctl list-timers | grep yvy-deter || echo "WARN: yvy-deter-daily.timer not enabled"
fi

# 4. Check WFS connectivity (dry-run)
curl -s -o /dev/null -w '%{http_code}' \
  "https://terrabrasilis.dpi.inpe.br/geoserver/deter-amz/ows?service=WFS&version=1.1.0&request=GetFeature&typeName=deter-amz:deter_amz&maxFeatures=1" \
  | grep -q '200' && echo "WFS OK" || echo "FAIL: WFS unreachable"
```

### Step 1 — Ingestão inicial (backfill 90 dias)

```bash
# First run with 90 days (avoid --full which downloads since 2016)
cd /media/smk/Shared/Code/Yvy
DB=backend-lua/data/yvy.db
if [ -x .venv/bin/python3 ]; then PY=.venv/bin/python3; else PY=python3; fi

# 1a. Download DETER polygons (últimos 90 dias)
"$PY" scripts/data/download_deter_wfs.py --days 90 --db "$DB" 2>&1 | tee /tmp/deter-download.log
echo "  [download_deter_wfs.py] inserted $(grep -o 'inserted [0-9]*' /tmp/deter-download.log | awk '{print $2}') rows"

# 1b. Roll up recent polygons into deter_alerts
"$PY" scripts/data/backfill_deter_alerts.py --rollup --days 90 --db "$DB" 2>&1 | tee /tmp/deter-rollup.log
echo "  [backfill_deter_alerts.py] upserted $(grep -o 'upserted [0-9]*' /tmp/deter-rollup.log | awk '{print $2}') rows"

# 1c. Cross DETER × CAR → deter_car_alerts (se CAR DB existe).
#     M2: o script imprime "wrote {n} deter_car_alerts rows" (linha 351), NÃO
#     "generated" — o grep abaixo casa com o output real. `--days` omite para
#     usar o default 7 (Pass 2 fire-driven usa janela curta; ver C1).
if [ -f backend-lua/data/car/car.db ]; then
  "$PY" scripts/data/cross_deter_car.py --db "$DB" --car-db backend-lua/data/car/car.db 2>&1 | tee /tmp/deter-cross.log
  echo "  [cross_deter_car.py] wrote $(grep -o 'wrote [0-9]*' /tmp/deter-cross.log | awk '{print $2}') CAR alerts"
else
  echo "  (cross_deter_car.py skipped — CAR DB not found)"
fi
```

### Step 2 — Backfill histórico (apenas se um JSON for fornecido)

**S1:** `deter-amazon-daily.json` **não existe** neste workspace — este step é
inerte hoje. Rodar apenas se um JSON histórico for adicionado em `scripts/data/`:

```bash
if [ -f scripts/data/deter-amazon-daily.json ]; then
  "$PY" scripts/data/backfill_deter_alerts.py --backfill scripts/data/deter-amazon-daily.json --db "$DB" 2>&1 | tee /tmp/deter-backfill.log
  echo "  [backfill_deter_alerts.py --backfill] inserted $(grep -o 'inserted [0-9]*' /tmp/deter-backfill.log | awk '{print $2}') rows from JSON"
else
  echo "  (deter-amazon-daily.json not found — only recent polygons available)"
fi
```

### Step 3 — Validar dados ingeridos

```bash
python3 -c "
import sqlite3
conn = sqlite3.connect('backend-lua/data/yvy.db')
cur = conn.cursor()
cur.execute('SELECT COUNT(*) FROM deter_polygons')
print(f'deter_polygons: {cur.fetchone()[0]} rows')
cur.execute('SELECT COUNT(*) FROM deter_alerts')
print(f'deter_alerts: {cur.fetchone()[0]} rows')
cur.execute('SELECT COUNT(*) FROM deter_car_alerts')
print(f'deter_car_alerts: {cur.fetchone()[0]} rows')
cur.execute('SELECT MIN(view_date), MAX(view_date) FROM deter_polygons')
print(f'date range: {cur.fetchone()}')
conn.close()
"
```

### Step 4 — Validar endpoint freshness

```bash
# Flush Redis cache antes de validar (C3: assumir Redis local; em produção usar
# o mesmo REDIS_URL do backend)
redis-cli DEL dashboard:freshness 2>/dev/null || true

curl -s http://localhost:5001/api/dashboard/freshness | python3 -m json.tool | grep -A5 '"deter"'
curl -s http://localhost:5001/api/dashboard/freshness | python3 -m json.tool | grep -A5 '"deter_car"'
```

### Tests to add/update
- **backend-lua/tests/test_deter.lua:** Já existe — validar que testes passam com dados reais
- **backend-lua/tests/test_dashboard_freshness.lua:** Já existe — validar que `deter.available = true` após ingestão
- **backend-lua/tests/test_deter_car.lua:** Já existe — validar que alertas CAR são gerados
- **scripts/data/tests/test_download_deter_wfs.py:** (novo) integration test **manual/produção** (CI não tem rede — ver S3/C3) — validar que `view_date` field name está correto (fail se TerraBrasilis mudar schema)

### Manual
1. Abrir `http://localhost:5001/dashboard`
2. Verificar que "DETER" aparece como `available: true` no painel de freshness
3. Filtrar mapa por camada "DETER" — deve mostrar polígonos
4. Verificar card "CAR Alerts" — deve mostrar severidade (crítico/alto/médio/baixo)
5. (Opcional) Validar que alertas DETER×UC/TI existem: `redis-cli GET alerts:deter_protected`

### Done criteria
- `deter_polygons` tem >0 rows com `view_date` nos últimos 90 dias
- `deter_alerts` tem >0 rows agregadas por `mun_geocod × classname × view_date`
- `deter_car_alerts` tem >0 rows **only if** CAR DB exists and has polygons
  - If CAR DB absent, `deter_car.available = false` é esperado (não é bug)
- `/api/dashboard/freshness` retorna `"deter": {"available": true, "rows": N}`
- `/api/dashboard/freshness` retorna `"deter_car": {"available": true|false, "rows": N}` (false se CAR DB ausente)

### CI validation (SHOULD)
**S3:** o snippet abaixo **não deve ir no CI** — `download_deter_wfs.py` precisa de
`requests` + rede para o WFS live, indisponíveis no CI (que hoje só faz syntax
check Lua/C). Em CI, validar apenas sintaxe (`py_compile`), sem rede:

```yaml
- name: Validate DETER scripts (syntax, no network)
  run: |
    python3 -m py_compile \
      scripts/data/download_deter_wfs.py \
      scripts/data/backfill_deter_alerts.py \
      scripts/data/cross_deter_car.py
```

> A execução real (download → rollup → cross) é um smoke test **manual/produção**,
> não um step de CI. Rodar no primeiro deploy e conferir `/api/dashboard/freshness`.

### Monitoring pós-ingestão (CONSIDER)
- Habilitar systemd timer: `systemctl enable --now yvy-deter-daily.timer`
- Monitorar logs: `journalctl -u yvy-deter-daily -f`
- Alertar se `deter.rows == 0` por >7 dias (via dashboard freshness)

## Standards / common-mistakes referenced
**S2:** só existe `.agents/common-mistakes/common-mistakes.md` — não há `.agents/standards/`.
Lições relevantes daquele arquivo:
- **#4 "Ingest writers must be pinned to the LIVE upstream schema"** — verificar `view_date` via DescribeFeatureType antes de confiar no campo (aplica ao WFS DETER).
- **#5 "Destructive update paths need marker-after-success + auto-restore"** — `download_deter_wfs.py` faz `DELETE FROM deter_polygons WHERE view_date = ?` antes de re-inserir; confirmar backup/verify antes de rodar com `--full`.
- **#1 "Test fixtures must be clock-relative"** — testes de ingestão devem usar `days_ago(n)`, nunca datas absolutas.
- **#6 "`or` on a pandas Series raises"** — `cross_deter_car.py` usa geopandas; verificar colunas com `in`, não com `or`.

## Estimated scope
**M (verificado, não L)** — O diagnóstico local já descartou os riscos que inflariam o
escopo:
- ✅ `python3` do sistema tem `shapely 2.1.2` (sem precisar de venv)
- ✅ `backend-lua/data/car/car.db` existe (6,8 GB)
- ✅ Templates `ansible/templates/yvy-deter-daily.{service,timer}.j2` já existem
  (`OnCalendar=*-*-* 04:30:00`)
- ✅ Redis + `redis-cli` presentes localmente

Trabalho real (diagnóstico → ingestão → validação):
1. Rodar Step 0 (diagnóstico, já em grande parte confirmado)
2. Executar backfill inicial (90 dias, não `--full`)
3. Validar DB + endpoints
4. (Opcional) garantir que o timer systemd esteja habilitado

## Open questions (CONSIDER from review)
- **C1 — Janela do cross ≠ janela do download/rollup:** Step 1c chama
  `cross_deter_car.py` sem `--days`, usando o default **7** (Pass 2 fire-driven),
  enquanto download/rollup usam **90**. Intencional — documentado no Step 1c para
  o implementador não "corrigir" por engano.
- **C2 — Rollup diário vs backfill:** o backfill inicial usa `--days 90`, mas o cron
  diário (`deter_daily.sh`) usa `--days 3`. Confirmar que, após o backfill, o timer
  diário roda com 3 para re-upsertar dias recentes (não conflita — `ON CONFLICT DO UPDATE`).
- **C3 — Flush de cache Redis:** `redis-cli DEL dashboard:freshness` assume Redis
  local. Ok neste workspace; em produção o `REDIS_URL` pode apontar para outro host
  — o flush deve usar o mesmo endpoint do backend.
- **Tests:** o plano lista um novo `scripts/data/tests/test_download_deter_wfs.py`
  com `network: true`. Como CI não tem rede (S3), esse teste é **só manual/produção**;
  não adicionar como step de CI.
