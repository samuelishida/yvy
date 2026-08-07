# TerraBrasilis (INPE) — Especificação de Dados e Capacidades

> Análise feita em 2026-08-07, diretamente do site, do GeoServer (WMS/WFS), dos
> dashboards e da área de download. Fonte: https://terrabrasilis.dpi.inpe.br/
> Licença: CC BY-SA 4.0.

---

## 1. Visão geral

O TerraBrasilis é a plataforma do INPE para acesso, consulta e análise dos dados
geoespaciais dos programas oficiais de monitoramento ambiental:

| Programa | Tema | Cobertura temporal |
|---|---|---|
| **PRODES** | Desmatamento anual (supressão de vegetação nativa) | 1988 → 2024 (classes anuais `d2000`–`d2024`) |
| **DETER** | Alertas de alteração de cobertura em tempo quase real | Diário (2016 → hoje) |
| **BdQueimadas / Fires** | Focos de queimada ativos | Diário / últimas 48h |
| **AMS** | Alerta e Monitoramento Sinótico (fogo + risco de propagação) | Hoje / horário |
| **Vegetação (Cerrado)** | Tipos de vegetação e ecorregiões | Estático |
| **Auxiliares** | Estados, municípios, UCs, TIs, biomas, hidrografia | Estático |

Serviços oficiais: **WMS**, **WFS**, **WCS**, **CSW** (padrões OGC / INDE),
mais dashboards interativos e área de download (vetor + raster).

---

## 2. Formas de acesso

### 2.1 GeoServer (WMS / WFS / WCS)
- Base: `https://terrabrasilis.dpi.inpe.br/geoserver`
- WMS raiz: `/wms?service=WMS&request=GetCapabilities` → **111 camadas**
- WFS raiz: `/ows?service=WFS&request=GetCapabilities` → **104 feature types**
- Workspaces confirmados: `prodes-brasil-nb`, `prodes-legal-amz`,
  `prodes-amazon-nb`, `prodes-cerrado-nb`, `prodes-caatinga-nb`,
  `prodes-mata-atlantica-nb`, `prodes-pampa-nb`, `prodes-pantanal-nb`,
  `deter-amz`, `deter-cerrado-nb`, `queimadas`, `ams1h`, `ams2`, `ams3`,
  `vegetation-cerrado`
- Endpoint por workspace: `/geoserver/<workspace>/ows?service=WFS&...`
- `DescribeFeatureType`: `/geoserver/<ws>/ows?service=WFS&version=1.0.0&request=DescribeFeatureType&typeName=<layer>`

### 2.2 Dashboards (dados agregados prontos)
Padrão: os dashboards são Angular/DC.js e carregam JSONs estáticos:

- **PRODES taxas** (Amazônia Legal, por estado/ano, 1988→2025):
  `https://terrabrasilis.dpi.inpe.br/app/prodes/dashboard/deforestation/files/rates2025.json`
  `https://terrabrasilis.dpi.inpe.br/app/prodes/dashboard/deforestation/files/last_update_date.json`
  (atualizado 2026-03-30; 2025 = 5.731 km²)
- **DETER agregado diário** (por município × classe × data):
  `https://terrabrasilis.dpi.inpe.br/app/dashboard/alerts/biomes/amazonia-nb/daily/data/deter-amazon-daily.json`
  (GeoJSON ~20 MB; há equivalente para cerrado)
- Dashboards de mapas: `/app/map/deforestation`, `/app/map/alerts`, `/app/map/vegetation`
- Dashboards de taxas/alertas/fogo:
  `/app/dashboard/deforestation/biomes/legal_amazon/rates`,
  `/app/dashboard/alerts/biomes/amazonia-nb/daily`,
  `/app/dashboard/fires/biomes/aggregated` (título: *"Queimadas X Desmatamento — Queimadas X CAR"*)
- Relatórios DETER (PDF): `/app/report/pantanal`, `/app/report/nf`
- **AMS**: `/ams/` (indicadores sinóticos)

### 2.3 Área de download
- Portal: `https://terrabrasilis.dpi.inpe.br/downloads/`
- Rasters PRODES por versão:
  `https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster/prodes_brasil_2024_v20260407.zip`
  (verificar ano/versão — PRODES 2025 ainda **não publicado**, 404)
- Vetores por bioma: desmatamento (PRODES), alertas (DETER, shapefile), auxiliares
- Rasters agregados do dashboard de fogo (cruzamento fogo × território):
  - `/download/fires-dashboard/car/raster/car_categories_amz_cerrado.zip`
  - `/download/fires-dashboard/deter/raster/deter_agregado_amz_cerrado.zip`
  - `/download/fires-dashboard/prodes/raster/prodes_agregado_amz_cerrado.zip`

### 2.4 Outros
- Catálogo de metadados (GeoNetwork + CSW): `/geonetwork/`
- Plugin QGIS: `https://plugins.qgis.org/plugins/terrabrasilis_datasource/`
- Programa Queimadas (focos): `http://www.inpe.br/queimadas/`
- BiomasBR (reprocessamentos): `https://data.inpe.br/biomasbr/`

---

## 3. Catálogo detalhado por dataset

### 3.1 PRODES — desmatamento anual
Camadas por bioma (`prodes-<bioma>-nb`), onde `<bioma>` ∈ {legal-amz, amazon,
cerrado, caatinga, mata-atlantica, pampa, pantanal}:

| Camada | Conteúdo |
|---|---|
| `yearly_deforestation` | Polígonos de desmatamento por ano (classes `dYYYY`) |
| `accumulated_deforestation_2000` / `_2007` | Desmatamento acumulado até o ano-base |
| `residual` | Vegetação secundária/regeneração (classes `rYYYY`) |
| `no_forest` | Áreas não-florestais monitoradas |
| `temporal_mosaic` | Mosaico temporal (todas as classes juntas) |
| `prodes_brasil` (workspace `prodes-brasil-nb`) | **Raster** Brasil completo (WMS/WCS) |
| `biomas_brasil` | Limites dos 6 biomas (vetor) |

**Atributos do polígono de desmatamento (WFS):**
`uuid, fid, state, path_row, main_class, class_name, year, area_km,
julian_day, image_date, publish_year, scene_id, source, satellite, sensor,
def_cloud, sub_class` + geometria `MultiPolygon`.

**Taxas agregadas (rates2025.json)** — por período anual (1/ago Y-1 → 31/jul Y)
e por estado (LOI), campo `area` em km². Períodos de 1988 a 2025.

### 3.2 DETER — alertas em tempo quase real
Camadas: `deter-amz:deter_amz`, `deter-cerrado-nb:deter_cerrado`
(workspaces também para Pantanal e Não-Floresta).

**Atributos do alerta (WFS):**
`gid, classname, quadrant, path_row, view_date, created_date, sensor,
satellite, areauckm, areamunkm, areatotalkm, uc, municipality, mun_geocod,
uf, publish_month` + geometria `MultiPolygon`.

**Classes DETER:** `DESMATAMENTO_VEG`, `DESMATAMENTO_CR`, `CICATRIZ_DE_QUEIMADA`,
`CORTE_SELETIVO`, `CS_DESORDENADO`, `CS_GEOMETRICO`, `DEGRADACAO`, `MINERACAO`.

**Agregado diário (deter-amazon-daily.json):** 1 registro por
(município-geocod × classe × data) com áreas em km² (campos `d`, `e`),
UF, nome do município.

### 3.3 Focos de queimada (BdQueimadas / Fires) e AMS
- WMS `queimadas:focos_48h_br_todosats` — focos das últimas 48h, todos os satélites.
- Dashboard de fogo cruza focos com vegetação nativa, supressão (PRODES/DETER) e CAR.
- **AMS** (`ams1h`/`ams2`/`ams3`): `active-fire-today` (focos de hoje),
  `fire-spreading-risk` (risco de propagação), `cs_150km_view`, `cs_5km_diff_view`,
  `municipalities_border`, `last_date`.
  Atributos: `view_date, viewed_at, satelite, municipio, biome, geocode`.

### 3.4 Camadas territoriais auxiliares (por bioma)
| Camada | Atributos |
|---|---|
| `states_<biome>` | `nome, sigla, geocodigo` |
| `municipalities_<biome>` | `nome, geocodigo, anoderefer` |
| `conservation_units_<biome>` | `nome, categoria, grupo, esfera, ano_cria` |
| `indigenous_area_<biome>` | `terrai_cod, terrai_nom, etnia_nome, fase_ti` |
| `biome_border` / `brazilian_legal_amazon` | limites |
| `hydrography` | hidrografia |
| `no_forest` | fitofisionomias não florestais |

### 3.5 Vegetação (Cerrado) e uso da terra
- `vegetation-cerrado:vegetation_types`: `level_1, level_2, level_3, legenda,
  cod_classe, area_km`
- `vegetation-cerrado:ecoregions`: `name`
- ~20 camadas por ecorregião + `srtm_relief_shading` (relevo SRTM)

---

## 4. Capacidades de cruzamento (o que dá para produzir)

As camadas já têm atributos que permitem cruzar sem join espacial explícito:

1. **Desmatamento × território**: polígonos PRODES já carregam `state`
   (UF); dá para agregar área desmatada por **estado, município (join via
   geocodigo), UC, TI** (join espacial com as camadas auxiliares).
2. **Alertas DETER × território**: já trazem `uf`, `municipality`,
   `mun_geocod`, `uc`; agregáveis por classe/dia/mês/UF/município/UC.
3. **Fogo × (vegetação / supressão / CAR)**: o próprio dashboard do INPE já
   cruza; rasters agregados prontos para download.
4. **Séries temporais**: PRODES anual (2000–2024), DETER diário, fogo diário.
5. **Taxas oficiais por estado/ano** (rates2025.json) para comparação com o
   que o Yvy calcula dos polígonos.
6. **Risco de propagação de fogo** (AMS `fire-spreading-risk`) — cruzável com
   focos ativos e alertas.
7. **Vegetação nativa vs desmatada**: `prodes_brasil` raster (classes
   `100`=vegetação nativa, `d*`=desmatamento, `r*`=regeneração) permite
   calcular área remanescente por região.

---

## 5. Spec de integração para o Yvy (priorizado)

### P0 — já temos / quase
- [x] Raster PRODES (d2000–d2024) → `deforestation_data` (2.001.410 pts)
- [x] Taxas históricas → `prodes_historical.json` (2008–2025)
- [x] Focos FIRMS (NASA) → `fire_data` (fonte alternativa ao BdQueimadas)

### P1 — alta utilidade, baixo esforço
- [ ] **DETER agregado diário** → nova tabela `deter_alerts` (geocod, classe,
      data, area_km², uf) com sync diário; alimentar alertas de desmatamento
      recente no app
- [ ] **Estados/municípios/UCs/TIs (atributos)** → enriquecer a classificação
      atual de focos e desmatamento (o Yvy já usa polígonos de estado; usar
      atributos do WFS em vez de só geometria)
- [ ] **Atualização automática do PRODES** quando o raster 2025 for publicado
      (script de check/download/ingest)

### P2 — análises novas
- [ ] **Área desmatada por município/UC/TI** (join espacial com polígonos
      PRODES anuais) → ranking + série temporal por município
- [ ] **Alertas DETER por UC/TI** (alerta de desmatamento dentro de área
      protegida, com `uc` já no atributo)
- [ ] **Focos × vegetação nativa**: cruzar focos com o raster PRODES
      (fogo em floresta vs. área já desmatada) — o Yvy já tem ambos
- [ ] **Risco de propagação de fogo** (AMS) sobreposto aos focos

### P3 — visão de longo prazo
- [ ] Vegetação do Cerrado (`vegetation_types`) para o mapa de biomas
- [ ] Integrar focos do **BdQueimadas** (INPE) como fonte complementar ao FIRMS

---

## 6. Endpoints-chave (resumo rápido)

```
# Taxas PRODES (por estado/ano)
https://terrabrasilis.dpi.inpe.br/app/prodes/dashboard/deforestation/files/rates2025.json

# DETER diário agregado (Amazônia)
.../app/dashboard/alerts/biomes/amazonia-nb/daily/data/deter-amazon-daily.json

# WMS (raster desmatamento Brasil)
.../geoserver/prodes-brasil-nb/wms?service=WMS&request=GetMap&layers=prodes_brasil&...

# WFS (polígonos de desmatamento anual, ex. Amazônia)
.../geoserver/prodes-amazon-nb/ows?service=WFS&version=1.0.0&request=GetFeature&typeName=yearly_deforestation&...

# Download raster PRODES (verificar versão mais recente)
https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster/prodes_brasil_2024_v20260407.zip
```
