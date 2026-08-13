# References — similar code in repo to learn from

## Templates for new Python ingest scripts
- `scripts/data/download_sinaflor_auth.py` — CKAN → DB dedicado → swap
  atômico `os.replace` → `--today`/`--force`/`--window`. Template para
  `download_embargo.py`.
- `scripts/data/cross_deter_car.py` — Shapely `intersection()` + CRS
  equal-area EPSG:5880 (fallback UTM 23S). Template para
  `compute_area_efetiva.py`.
- `scripts/data/download_mapbiomas_alerta.py` — alertas MapBiomas → DB
  dedicado + rtree. Template para `compute_area_efetiva.py` (fonte de
  alertas).

## Templates for new Lua lookups
- `backend-lua/app/lookups/sinaflor_lookup.lua` — `is_loaded()` memo 60s,
  `PRAGMA query_only=ON`, graceful degradation. Template para
  `embargo_lookup.lua` e `area_efetiva_lookup.lua`.
- `backend-lua/app/lookups/car_prodes.lua` — precompute + `version_key`
  invalidação. Template para o DB de área efetiva.
- `backend-lua/app/lookups/car_protected_overlap.lua` — sobreposição UC/TI
  (Monte-Carlo). Reutilizado no laudo.

## Templates para jobs agendados
- `ansible/templates/yvy-risk-monitor.service.j2` + `.timer.j2` — oneshot,
  `Persistent=true`, `RandomizedDelaySec=300`, staggered. Template para
  `yvy-area-efetiva` e `yvy-embargo`.

## Templates para deploy
- `scripts/deploy/sync-sinaflor.sh` — scp do DB dedicado + verificação.
  Template para `sync-area-efetiva.sh` e `sync-embargo.sh`.

## Templates para testes
- `backend-lua/tests/test_risk_score.lua` — temp DB com `os.time()`, Redis
  stub, teardown. Template para `test_area_efetiva_lookup.lua` e
  `test_embargo_lookup.lua`.
- `backend-lua/tests/test_risk_report.lua` — teste do renderer PDF.
- `backend-lua/tests/helpers.lua` — `days_ago(n)`, `fake_ctx(args)`.

## Frontend
- `frontend/src/components/RiskIntelligence/RiskIntelligence.js` — página
  existente a estender (Inc 4).
- `frontend/src/utils/apiCache.js` — `cachedFetch`/`invalidateApiCache`.
- `frontend/src/App.js` — rotas lazy.
