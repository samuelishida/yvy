# Shaping decisions — CAR Risk Expansion

## Alternatives considered

### Área efetiva: onde calcular?
- **Chosen:** offline em Python (Shapely + CRS equal-area EPSG:5880),
  pré-computada em DB dedicado com `version_key`. Espelha `cross_deter_car.py`
  + `car_prodes`/`car_protected_overlap`.
- Rejected: interseção em Lua (sem primitiva; custo no loop single-threaded),
  interseção on-the-fly por request (lento, sem cache, repete trabalho).

### Embargo: fonte?
- **Chosen:** CKAN `dadosabertos.ibama.gov.br` (mesmo padrão Sinaflor), DB
  dedicado `embargo.db` com swap atômico.
- Rejected: API IBAMA com token (moving part), scraping (frágil).

### Laudo: como enriquecer?
- **Chosen:** estender `render_risk_report.py` (reportlab) para multi-página,
  consumindo um `context.json` montado pelo backend. Mantém audit trail
  server-side.
- Rejected: jspdf no frontend (quebra requisito de evidência/compliance).

## Scope decisions (user-confirmed)
- **Core 3 primeiro:** área efetiva, embargo, laudo enriquecido. SIGEF/SNCI e
  CAR-status adiados (datasets não verificados).
- **White-label adiado:** single-tenant, branding Yvy.
- **Fontes assumidas open-data** com verificação de schema em runtime.

## Why this DAG
- Inc 1 (área efetiva) e Inc 2 (embargo) são independentes — podem rodar em
  paralelo. Ambos alimentam Inc 3 (score + laudo). Inc 4 (frontend) depende
  só de Inc 3.
- Cada incremento é um PR que passa CI independentemente.

## Pre-flight: embargo CKAN geometry (Inc 2) — VERIFIED 2026-08-13
- Dataset: `fiscalizacao-termo-de-embargo` (dadosabertos.ibama.gov.br).
- **Geometria EXISTE**: o resource principal `termo_embargo_csv.zip` tem a
  coluna `GEOM_AREA_EMBARGADA` (WKT POLYGON/MULTIPOLYGON) + centroide
  `NUM_LONGITUDE_TAD`/`NUM_LATITUDE_TAD`.
- **Sem coluna `cod_imovel`** → matching é ESPACIAL (lat/lon → polígono CAR),
  como o fallback do sinaflor. `resolve_car` usa o centroide.
- Status: `SIT_CANCELADO` (N=ativo, S=cancelado), `SIT_DESEMBARGO` (S=desembargado).
- Schema completo (geom BLOB + rtree + `get_at`) é válido.
