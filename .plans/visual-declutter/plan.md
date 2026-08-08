# Visual Declutter — Redução de Poluição Visual

## Context

O frontend do Yvy sofre de poluição visual em 3 telas principais:

- **Home (mapa)**: 4 camadas de dados ligadas por padrão (satélite + focos + PRODES + TI + UC) + chrome sobreposto (layer bar com **8 pílulas**, legenda de natureza, float panel, atribuição Leaflet, **form de verificação PRODES por recibo CAR**). O mapa nasce saturado. **Pós-TerraBrasilis (plano concluído) + TerraClass removido:** Cerrado Veg e AMS iniciam OFF, mas os 3 `TileLayer` (PRODES/CAR/CerradoVeg) continuam sempre montados e baixando tiles mesmo com opacity 0.
- **Dashboard**: cards sem título (TIAtRisk), combo card com 2 métricas de unidades diferentes, 4 componentes mortos não importados, duplicação de informação entre cards, **e zero aproveitamento dos dados TerraBrasilis** (DETER, CAR, AMS, deforestation) — nenhum card cruza essas fontes.
- **News**: descrições com boilerplate de RSS ("O post ... apareceu primeiro em ..." / "The post ... appeared first on ...") e textos sem clamp quebrando a consistência visual dos cards.

**Intended outcome**: um frontend mais limpo onde cada tela mostra apenas o essencial por padrão, com o usuário podendo expandir conforme necessário.

## Architectural decisions

- **Decision: manter pílulas da layer bar, só reduzir defaults.** Transformar em dropdown "Camadas" foi rejeitado como disruptivo demais para este plano. A mudança é só de estado inicial (`useState(true)` → `useState(false)` para PRODES/TI/UC). Alternativa rejeitada: dropdown Google Maps-style (requer redesign da layer bar, novo componente). **Pós-TerraBrasilis: 8 pílulas é o teto aceito** — CAR/CerradoVeg/AMS já iniciam OFF e são "camadas de investigação" (ligam sob demanda); agrupar em "Imóveis & uso do solo" fica como follow-up (SHOULD-FIX #2) se a barra pesar no mobile. (TerraClass removido do projeto.)
- **Decision: manter os 2 sistemas de cor (natureza + confidence fallback), consertar a legenda.** Unificar para natureza-only foi rejeitado porque ~50% dos focos ainda não têm classificação (caem no fallback). A legenda atual só mostra o sistema de natureza — o fix é adicionar indicação visual de quando o fallback está ativo. Alternativa rejeitada: forçar classificação de todos os focos (backfill ainda em andamento).
- **Decision: grid customizado para agregação de focos, sem dependência nova.** Canvas overlay renderizando contagem por célula no espaço de tela. Sem `leaflet.markercluster` ou qualquer npm extra. Alternativa rejeitada: markercluster (dependência pesada, ~30KB gzipped, API diferente dos CircleMarkers atuais que usam preferCanvas).
- **Decision: boilerplate RSS removido no backend (scrapers.lua), não no frontend.** Conserta na origem para todos os consumidores (incluindo cache e futuros clientes). Regex aplicado após extração da description, antes do insert.
- **Decision: clamp de descrição no CSS, não truncate no backend.** Preserva o texto completo para busca/SEO; o clamp é puramente visual. O botão "Ler mais" já leva ao artigo original.

## Assumptions and answers from code

- **Decision: Home defaults atuais são todos `useState(true)`.** Source: code @ `frontend/src/components/Home.js:1200-1203` — `showDeforest`, `showFires`, `showIndigenous`, `showConservation` todos inicializados como `true`. `showCar`, `showCerradoVeg`, `showAms` já iniciam `false` (pós-TerraBrasilis; `showTerraClass` removido com o dataset) — **o declutter só precisa mudar PRODES/TI/UC**.
- **Decision: scrapers.lua extrai description do RSS `<description>`, `<summary>`, ou `<content>`.** Source: code @ `backend-lua/app/scrapers.lua:160-164`. O boilerplate vem do feed original, não é adicionado pelo scraper. O local correto para strip é após `:gsub("<[^>]+>", " ")` na linha 162.
- **Decision: TIAtRisk não tem header.** Source: code @ `frontend/src/components/Dashboard/TIAtRisk.js:41` — retorna `<div className="dash-section"><div className="ti-table">` sem heading. Confirmado no snapshot da página.
- **Decision: 4 componentes existem mas não são importados.** Source: grep em `frontend/src/**` — `StateSparklines`, `FireTrend`, `HealthContext`, `DashboardFilters` não têm `import` em nenhum arquivo além de sua própria definição.
- **Decision: News.css não tem line-clamp.** Source: grep `line-clamp` em `frontend/src/components/News.css` — 0 matches. O `overflow: hidden` existe no `.news-article` e `.news-image-wrap`, mas não no `<p>` da descrição.
- **Decision: FloatPanel abre por padrão com `useState(true)`.** Source: code @ `frontend/src/components/Home.js:482` — `const [open, setOpen] = useState(true)` (linha verificada; o Inc 2 referencia a mesma 482).

## Risks accepted

- **Grid de agregação pode ter performance ruim em dados muito densos (>50k focos)**: mitigado pelo viewport-filter existente + kill switch (toggle local OFF por padrão) que permite desabilitar sem redeploy. Risco aceito; se lento, ajustar cellSize ou limite máximo de células.
- **Mudança de defaults pode surpreender usuários recorrentes**: mitigado por manter os toggles visíveis e fáceis de reativar; a primeira impressão para novos usuários melhora significativamente. Aceito; sem feature flag.
- **Remoção de boilerplate RSS pode ter falsos positivos**: regex aplicado só em description (não title), e padrões são bem específicos cobrindo PT e EN. Risco baixo; testar com o corpus existente de 744 notícias.
- **Dead code removal**: se algum componente for referenciado dinamicamente (string ref, lazy load futuro), a remoção quebra. Mitigado pelo grep exaustivo em todos os arquivos do projeto + remoção de chaves i18n órfãs. Risco baixo.

## Increment DAG

Incrementos 1-5 são independentes entre si. **Inc 6 depende (soft) do Inc 3**: os 2 slots liberados pelo split do combo são preenchidos pelos cards novos.

- Inc 1 — Backend: RSS boilerplate cleanup (S) — depends on: none — unblocks: none — **STATUS: done (2026-08-07)**
- Inc 2 — Frontend: Home defaults + News clamp + FloatPanel empty state (S) — depends on: none — unblocks: none — **STATUS: done (2026-08-07)**
- Inc 3 — Dashboard: headers + dead code removal + combo split (M) — depends on: none — unblocks: 6 (soft) — **STATUS: done (2026-08-07)**
- Inc 4 — Nature legend: dual-system indicator (S) — depends on: none — unblocks: none — **STATUS: done (2026-08-07)**
- Inc 5 — Fire aggregation grid overlay (L) — depends on: none — unblocks: none — **STATUS: done (2026-08-07)** — **REMOVIDO (2026-08-08, pedido do usuário):** o botão "Densidade", o `FireGridOverlay`/`ZoomBridge` e o CSS `.fire-grid-canvas` foram removidos de `Home.js`/`Home.css`/`i18n.js` (usuário não entendeu o recurso e pediu para tirar). Fix associado: `TileLayer` de CAR e Cerrado Veg ganharam `minNativeZoom={6}` (tiles existem só em z6+; antes pediam z5 → PNG transparente / minZoom bloqueava no zoom padrão)
- Inc 6 — Dashboard: TerraBrasilis data crossing cards (M) — depends on: 3 (soft — usa os slots do split do combo) — unblocks: none — **STATUS: done (2026-08-07)** — **nota: também toca backend (nova rota `/api/deter/car-alert-stats` em `routes/deter.lua` + `main.lua`)**

---

## Increments

### Inc 1 — Backend: RSS boilerplate cleanup (S)

**Depends on:** none
**Unblocks:** none
**Done criteria:** após rodar `clean_news_boilerplate.lua` (local + prod) e invalidar o cache `news:*`, `curl http://localhost:5001/api/news?lang=pt&page_size=20` **e** `...&lang=en` não retornam "apareceu primeiro em" / "appeared first on" em nenhuma description (PT ou EN).

> **Implementation note (2026-08-07):** o padrão canônico (2 regexes) deixava **65+ linhas residuais** no corpus real (744 notícias) — violando o done criteria. Padrões expandidos em `utils.strip_boilerplate` para cobrir as variantes reais: "appeared first in" (traduções), ordem "first appeared on/in", prefixos "The \<Word\> post" (ex: "The Dell post", "The Alcântara post" — `[^%s]+ post.+` sem espaço literal porque o título pode começar com vírgula), "<Owner>'s \<Word\> post" (ex: "Petrobras' Plan post"), e sufixos truncados (sem fonte — `$`-anchored ou com reticências "…"). Verificado no corpus completo: 0 residual PT, 0 residual EN, 0 over-strip (nenhuma description < 20 chars). Testes: 12 casos em `test_utils.lua` (não `test_scrapers.lua` — função mora em utils.lua).

#### Files to touch

##### backend-lua/app/utils.lua
- What changes: **adicionar `_M.strip_boilerplate(desc)` aqui, não em scrapers.lua** (SHOULD-FIX #5) — `clean_news_boilerplate.lua` precisa da função e `require("app.scrapers")` puxaria `lxp`/`http_client`/`browser_fallback`. `utils.lua` já hospeda `normalize_title` (helper compartilhado de news). Padrões refinados com `[^%.]+` na fonte — o `.+` ganancioso engoliria texto após o boilerplate (SHOULD-FIX #3)
- Function(s):
  ```lua
  function _M.strip_boilerplate(desc)
      if not desc or desc == "" then return desc end
      desc = desc:gsub("[Oo] post .+ apareceu primeiro em [^%.]+%.?%s*", "")
      desc = desc:gsub("[Tt]he post .+ appeared first on [^%.]+%.?%s*", "")
      desc = desc:gsub("^%s+", ""):gsub("%s+$", "")
      return desc
  end
  ```
- Data shapes: `desc` (string) → string limpa
- Integration points: chamado por `scrapers.lua` (parser XML) e por `clean_news_boilerplate.lua`
- Error paths: nil/"" → retorna como está

##### backend-lua/app/scrapers.lua
- What changes: usar `utils.strip_boilerplate(desc)` no parser XML, **antes da comparação de tamanho** (linha 163) para que a lógica "keep longest description" use o texto já limpo
- Function(s): após `local desc = text:gsub("<[^>]+>", " ")...` (linha 162), aplicar `desc = utils.strip_boilerplate(desc)` antes da condição `if not current.description or #desc > #(current.description or "")`
- Data shapes: `current.description` (string) — limpo dos padrões
- Integration points: chamado por `tools/news_sync.lua` via `scrapers.fetch_all()`
- Error paths: desc vazia após strip → mantém desc original (fallback); nil → skip

##### backend-lua/tools/clean_news_boilerplate.lua (new)
- What changes: **cleanup one-time das linhas existentes no banco** (MUST-FIX). O re-sync só re-fetch dos ~20-50 itens mais recentes por feed; artigos antigos manteriam boilerplate para sempre. Ferramenta Lua (padrão `dedupe_and_enrich.lua`) que itera `news`, aplica `utils.strip_boilerplate` em `description` **e `description_en`**, e faz UPDATE transacional
- Function(s): `run()` — SELECT url + `json(data)` AS data_text, decodifica, strip ambos os campos, UPDATE com `esc()` (SQL escaping), tudo em `BEGIN`/`COMMIT`
- Data shapes: **round-trip JSONB correto (SHOULD-FIX #2)**: `UPDATE news SET data = jsonb(json_set(json(data), '$.description', ?, '$.description_en', ?)) WHERE url = ?` — `json_set` no BLOB retorna texto; o `jsonb()` é obrigatório na escrita (AGENTS.md: nunca ler o BLOB cru). **Guard:** só incluir `description_en` no `json_set` se a chave já existir e for não-vazia — senão o `json_set` criaria `"description_en": null` em linhas que nunca tiveram EN
- Integration points: rodado manualmente no deploy (local + prod), uma vez, após o deploy do código
- Error paths: linha com JSONB corrompido → skip + log; nenhuma linha alterada → no-op
- Observability: imprime contagem de linhas alteradas (idempotente — segunda execução reporta 0)

##### backend-lua/tests/test_scrapers.lua (new)
- What changes: teste unitário de `utils.strip_boilerplate` (padrão Busted, fixtures inline — sem rede, espelha `test_geo.lua`)
- Function(s): `describe("strip_boilerplate")` — casos: PT ("O post X apareceu primeiro em Y."), EN ("The post X appeared first on Y."), já-limpo (no-op), desc vazia/nil, **texto após o boilerplate é preservado** ("... appeared first on Y. Extra info" → "... Extra info", garante o `[^%.]+`)
- Integration points: `make test-lua` roda todos os testes de `backend-lua/tests/`
- Error paths: n/a

#### Edge cases
- Descrição que contém "apareceu primeiro" como parte legítima do texto (ex: matéria sobre estreia de algo) — improvável pela estrutura fixa do padrão RSS: "O post [título] apareceu primeiro em [fonte]."
- Feeds em inglês vs português — regex cobre ambos
- Descrição já limpa (sem boilerplate) — gsub é no-op
- Linhas existentes no banco — cobertas pelo `clean_news_boilerplate.lua` (one-time), incluindo `description_en` já traduzido (SHOULD-FIX #3)

#### Verification
- Run: `make test-lua` — todos os testes passam, incluindo o novo `test_scrapers.lua` (a contagem "83/83" está defasada: hoje há 11+ arquivos em `backend-lua/tests/`)
- Run: `lua5.1 backend-lua/tools/clean_news_boilerplate.lua` — reporta N linhas alteradas; segunda execução reporta 0 (idempotente)
- Teste manual **após invalidar o cache Redis**: limpar `news:*` (ou aguardar o próximo sync, que invalida via `redis.delete_pattern("news:*")`), depois `curl -H "X-API-Key: $API_KEY" http://localhost:5001/api/news?lang=pt&page_size=20 | python3 -c "import sys,json; [print(a.get('description','')[:80]) for a in json.load(sys.stdin)]"` — nenhuma linha com "apareceu primeiro"/"appeared first"; repetir com `lang=en` (SHOULD-FIX #5)
- Done: zero ocorrências de boilerplate nas descriptions da API (PT e EN) após cleanup + cache invalidado

---

### Inc 2 — Frontend: Home defaults + News clamp + FloatPanel empty state (S)

**Depends on:** none
**Unblocks:** none
**Done criteria:** (a) Home carrega com mapa mostrando apenas focos + satélite; (b) descrições de notícias clampam em 3 linhas; (c) float panel colapsado por padrão, header mostra a contagem real após o fetch.

#### Files to touch

##### frontend/src/components/Home.js
- What changes: alterar defaults de `useState(true)` para `useState(false)` em showDeforest, showIndigenous, showConservation (linhas 1200-1203). **MUST-FIX: desmontar condicionalmente os TRÊS `TileLayer` sempre-montados** — PRODES (`Home.js:1021`), CAR (`:1035`) e CerradoVeg (`:1049`) usam `opacity={x ? 0.33 : 0}` e o Leaflet baixa tiles mesmo com opacity 0. Trocar para `{showDeforest && <TileLayer .../>}` (idem CAR/CerradoVeg) para que defaults OFF realmente parem o download no primeiro load. **CerradoVeg é o maior desperdício: OFF por padrão mas ainda baixando tiles.** (TI/UC/AMS já são condicionais via `{showX && ...}` — sem mudança; o `TileLayer` do TerraClass foi removido do projeto.)
- Function(s): `Home()` — mudar `useState(true)` → `useState(false)` nas linhas 1200-1203 (showDeforest/showIndigenous/showConservation); `MapaCard` — envolver os **três** `TileLayer` (PRODES `:1021`, CAR `:1035`, CerradoVeg `:1049`) em render condicional
- Data shapes: boolean state values
- Integration points: `MapaCard` recebe essas flags como props; `FloatPanel` recebe `alerts`
- Error paths: nenhum (mudança de estado inicial + render condicional); religar a camada remonta o TileLayer e re-fetcha os tiles (esperado)

##### frontend/src/components/News.css
- What changes: adicionar `display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden;` ao `p` dentro de `.news-content`
- Data shapes: CSS-only change
- Integration points: componente `NewsArticle`
- Error paths: nenhum (CSS degrada graciosamente em browsers sem suporte a -webkit-line-clamp)

##### frontend/src/components/Home.js (FloatPanel)
- What changes: `FloatPanel` (linha 482) — **sempre colapsado no mount** e **sem auto-open** (SHOULD-FIX #4): os alerts chegam ~1-2s após o mount (prod tem 461; **pós-TerraBrasilis o painel agrega 9 tipos de alerta, incluindo `deter_protected`** — collapse-by-default é ainda mais crítico) — auto-open tornaria o collapse inócuo. O header colapsado (`fp-summary`) já mostra a contagem viva; o usuário expande sob demanda. Adicionar flag `loaded` (ou `alerts != null`) para distinguir "carregando" de "vazio" e exibir "0 alertas" em vez de "—" após o fetch.
- Function(s): `FloatPanel` — `useState(false)` (sempre colapsado no mount); remover o `useEffect` de auto-open; flag `loaded` para o hero
- Data shapes: n/a
- Integration points: `Home` → `MapaCard` → `FloatPanel`
- Error paths: nenhum
- **Nota (CONSIDER #5):** se no futuro decidirmos auto-abrir, gatear com `userClosedRef` (setado no clique de fechar) para não reabrir contra a vontade do usuário

#### Edge cases
- Usuário com localStorage de preferências — defaults só afetam primeira montagem; se usuário já usou os toggles, o estado persiste na sessão React
- News sem description — `<p>` nem renderiza (já tem guard `{description && <p>...}`), clamp não se aplica
- FloatPanel: sempre colapsado no mount; flag `loaded` distingue "carregando" (—) de "vazio" (0 alertas) após o fetch — sem auto-open
- **CONSIDER #1:** persistir os toggles de camada (`showDeforest`/`showIndigenous`/`showConservation`) em localStorage (padrão `setCacheSync` de News) para usuários recorrentes manterem a preferência — opcional, decidir na implementação

#### Verification
- Run: `cd frontend && npm run build` (sem erros)
- Visual: abrir Home → confirmar só fogo+satélite visíveis; abrir News → confirmar descrições clampadas; Home com 0 alertas → float panel colapsado
- Done: Home limpa no primeiro load, News com cards uniformes, float panel recolhido quando vazio

---

### Inc 3 — Dashboard: headers + dead code removal + combo split (M)

**Depends on:** none
**Unblocks:** none
**Done criteria:** (a) TIAtRisk tem título; (b) 4 arquivos de componentes mortos removidos; (c) combo card separado em 2 cards independentes; (d) `npm run build` passa.

#### Files to touch

##### frontend/src/components/Dashboard/TIAtRisk.js
- What changes: adicionar `<div className="chart-card__header">` com `<h2>` antes da tabela
- Function(s): `TIAtRisk()` — wrapper com header padronizado
- Data shapes: n/a (só markup)
- Integration points: importado por `Dashboard.js`
- Error paths: nenhum

##### frontend/src/components/Dashboard/StateSparklines.js, FireTrend.js, HealthContext.js, DashboardFilters.js
- What changes: **DELETE** — arquivos removidos do filesystem
- Verification: `grep -r "StateSparklines\|FireTrend\|HealthContext\|DashboardFilters" frontend/src/` retorna 0 resultados (fora os próprios arquivos deletados)
- **i18n cleanup (MUST-FIX):** remover chaves órfãs `fireTrend` / `fireTrendSub` de `frontend/src/i18n.js` (PT: linhas 126-127, EN: 294-295) — único consumidor é o `FireTrend` (morto). Confirmado via grep: `stateSparklines`/`dashboardFilters`/`healthContext` não existem no i18n, então só essas 2 chaves (PT+EN)

##### frontend/src/components/Dashboard.js
- What changes: split do combo card em dois `chart-card` separados: um para biomas 24h, outro para alertas por categoria, com classes `chart-card--biomes` / `chart-card--alerts` (para o min-height substituto no CSS)
- Function(s): `Dashboard()` — substituir `<div className="chart-card chart-card--combo">` por `<div className="chart-card chart-card--biomes">` e `<div className="chart-card chart-card--alerts">`
- Data shapes: n/a (reorganização de JSX)
- Integration points: `dash-body` grid layout (2-col). **Layout resultante (intencional):** `.chart-card--wide` **não tem regra CSS** (0 matches em `frontend/src/**/*.css`), logo HistoricalTrend ocupa 1 coluna. Após o split a grade vira `[HistTrend|biomas] [alertas|TIAtRisk] [NatureStats|GeoBreakdown]` — 6 cards fechando 3 linhas. **Não adicionar** regra `wide` nem recombinar os cards. **Os 2 slots liberados pelo split são preenchidos pelo Inc 6 (DETER Activity + Fogo×Veg).**
- Error paths: nenhum

##### frontend/src/components/Dashboard.css
- What changes: remover regras `.chart-card--combo` (linhas ~300-315), `.combo-card__section`, `.combo-card__divider`; remover `.dash-filters`, `.dash-filters__group`, `.dash-filters__label`, `.chip-row`, `.chip`, `.chip--active`, `.chip-swatch` (linhas ~185-255) — todas são dead CSS após split do combo e remoção do DashboardFilters. **SHOULD-FIX #1: adicionar min-height substituta** — `.combo-card__section` tinha `min-height: 260px` (`Dashboard.css:301-306`); sem substituta os 2 cards novos (~250px) ficariam tortos ao lado do HistoricalTrend (~430px). Ex.: `.chart-card--biomes, .chart-card--alerts { min-height: 260px; }` (ou no `.bar-chart` interno)
- Verification: grep cada seletor removido em `frontend/src/` para confirmar que não há outro consumidor após o split

#### Edge cases
- Mobile (1-col) — os dois novos cards empilham naturalmente via `@media (max-width: 800px) { grid-template-columns: 1fr; }`
- Dashboard sem dados — loading state já cobre

#### Verification
- Run: `cd frontend && npm run build`
- Visual: Dashboard com todos os cards titulados, sem combo card, sem erros no console
- Done: build passa, 4 arquivos removidos, dashboard visualmente consistente

---

### Inc 4 — Nature legend: dual-system indicator (S)

**Depends on:** none
**Unblocks:** none
**Done criteria:** legenda de natureza no mapa mostra tanto as 4 cores de natureza quanto indica que focos não-classificados usam cores por confidence.

#### Files to touch

##### frontend/src/components/Home.js
- What changes: atualizar o bloco `.nature-legend` para mostrar dois grupos: (1) cores de natureza com os 4 itens existentes; (2) separador + gradiente de confidence (nominal=red → high=orange → low=yellow) com labels. Ambos os grupos visíveis sempre que `showFires=true`.
- Function(s): bloco JSX condicional `{showFires && (<div className="nature-legend">...)}` — adicionar segundo grupo com gradiente inline
- Data shapes: n/a (JSX estático com cores hardcoded dos `FIRE_STYLES`)
- Integration points: renderizado condicionalmente no `MapaCard`
- Error paths: nenhum

#### Edge cases
- Focos 100% classificados (todos têm nature) — a parte de confidence da legenda fica supérflua mas não incorreta
- Focos 0% classificados — a legenda de natureza mostra zero itens; confidence é o único sistema visível
- **AMS overlay usa os mesmos matizes da legenda (red/orange — `#ef4444`/`#f97316` em `Home.js:1108-1118`)** (CONSIDER #3): aceito porque o overlay AMS é ligado sob demanda e raramente junto com a legenda; a legenda pode ganhar uma linha "AMS (camada separada)" se a colisão incomodar
- **Mobile (CONSIDER #4):** a legenda cresce com 2 grupos — conferir no `@media (max-width: 720px)` se o bloco bottom-left não colide com o float panel bottom-right em telas estreitas

#### Verification
- Visual: abrir Home, verificar legenda no canto inferior esquerdo
- Done: legenda explica ambos os sistemas de cor

---

### Inc 5 — Fire aggregation grid overlay (L)

**Depends on:** none
**Unblocks:** none
**Done criteria:** **com o toggle do grid ativo** (`enabled=true` — kill switch), em zoom ≤ 7 o mapa mostra grid de densidade em vez de dots individuais; em zoom ≥ 8 transiciona para dots (comportamento atual). Com `enabled=false` (default), o comportamento é 100% o atual — o critério vale com o grid ligado (SHOULD-FIX #6).

#### Files to touch

##### frontend/src/components/Home.js
- What changes: novo componente `FireGridOverlay` que renderiza um `<canvas>` posicionado sobre o mapa via `L.DomUtil.create('canvas', 'fire-grid-canvas', map.getContainer())` dentro de `useEffect`, com `position:absolute; inset:0; pointer-events:none` e dimensões sincronizadas com `map.getSize()` no `moveend`/`zoomend`. **Não usar `overlayPane`** (SHOULD-FIX #1): panes sofrem `transform: translate/scale` do mapa — grid em screen-space desliza no pan e borra no zoom fracionário (`zoomSnap=0.5`). Incluir **kill switch**: toggle local (`useState`) default OFF, ativável via botão na layer bar ou via `?grid=1` query param.
- Function(s):
  - `FireGridOverlay({ fires, visible, thresholdZoom, enabled })` — hook `useMap` + `useEffect` para criar/destruir canvas no pane do Leaflet; recalcula grid no `moveend`/`zoomend`; renderiza retângulos coloridos por densidade
  - Modificar `MapaCard` para mostrar grid quando `enabled && zoom <= threshold` e dots quando `!enabled || zoom > threshold`
- Data shapes:
  - Input: `fires: Array<{lat, lon}>`, `visible: boolean`, `thresholdZoom: number`, `enabled: boolean`
  - Grid cell: `{x, y, count, density, color}` — calculado no espaço de tela (containerPoint), cellSize ~40px
- **Color scale**: usar escala de 5 tons ancorados nos mesmos matizes do app:
  - 0: transparente (sem célula)
  - 1-5 focos: `rgba(0, 201, 122, 0.15)` (green-dim)
  - 6-20: `rgba(0, 201, 122, 0.35)`
  - 21-50: `rgba(251, 191, 36, 0.45)` (amber)
  - 51-100: `rgba(249, 115, 22, 0.55)` (orange)
  - 101+: `rgba(239, 83, 80, 0.65)` (red)
- **Canvas strategy**: HTML `<canvas>` **anexado a `map.getContainer()`** (não ao `overlayPane`). O `overlayPane` recebe `transform: translate/scale` do mapa — um grid em screen-space (containerPoint) deslizaria no pan e borraria no zoom. Anexar ao container com `position:absolute; inset:0; pointer-events:none` e z-index acima dos panes (abaixo dos controles) deixa o grid estático e nítido; redesenho no `moveend`/`zoomend` via `requestAnimationFrame`; `resize` recria o canvas com novas dimensões.
- Integration points: `MapaCard` → opcionalmente renderiza `FireGridOverlay` em vez dos `FireMarker`s quando zoom baixo
- Error paths: canvas context null → catch e fallback para dots; grid vazio → canvas clear; resize → recria canvas com novas dimensões

##### frontend/src/Home.css
- What changes: estilos para o canvas overlay (position absolute, pointer-events none, z-index entre tiles e controls)
- Data shapes: CSS
- Integration points: `.fire-grid-canvas`
- Error paths: nenhum

#### Edge cases
- Transição grid→dots durante zoom animation — usar `zoomend` (não `zoom`) para evitar flicker
- Viewport com 0 focos — grid não renderiza, mapa fica limpo
- Resize da janela — `moveend` já triggera recálculo; adicionar listener `resize` se necessário
- Pan rápido — grid recalcula no `moveend` (debounced pelo rAF existente no viewport filter)
- Grid cells com poucos focos — definir threshold mínimo de opacidade para células com 1-2 focos
- Contagem por célula no hover — **fora de escopo** (exigiria reabilitar pointer-events + hit-testing no canvas); documentado em Open Questions (CONSIDER #2)
- **Popup de fogo cresceu para ~3 linhas (pós-TerraBrasilis): nature + vegetation + AMS** (`Home.js:248,260`) — o grid (zoom baixo) esconde os dots, então o popup só é alcançado em zoom alto; consistente, mas o `FirePopupContent` pode compactar as linhas de contexto se a densidade incomodar

#### Verification
- Run: `cd frontend && npm run build`
- Visual: abrir Home com zoom 5 (Brasil inteiro) → grid visível; dar zoom in até 8+ → dots aparecem; zoom out → grid volta
- Perf: verificar que `moveend` com grid + 20k focos não causa jank (>30fps)
- **Perf pós-TerraBrasilis: re-testar com dataset dual-source (FIRMS + BdQueimadas)** — o volume de `fire_data` pode dobrar; o grid agrega por lat/lon sem mudança de código, mas validar o limite de células
- Done: grid funcional em zoom baixo, transição suave para dots em zoom alto

---

### Inc 6 — Dashboard: TerraBrasilis data crossing cards (M)

**Depends on:** Inc 3 (soft — usa os slots liberados pelo split do combo)
**Unblocks:** none
**Done criteria:** Dashboard mostra 3 cards novos com dados TerraBrasilis (DETER por classe, severidade de alertas CAR, contexto fogo×vegetação), todos titulados, com chaves i18n (PT+EN) e sem erros no build.

#### Files to touch

##### frontend/src/components/Dashboard.js
- What changes: adicionar 3 novos cards após o split do combo (Inc 3). **Grade final: 9 cards — 8 preenchem 4 linhas (2-col) + `[GeoBreakdown]` como 9º card na linha 5 (orphan, 1 coluna).** `[HistTrend|DETER Activity] [Biomas 24h|Fogo×Veg] [Alertas por categoria|CAR Alerts Severity] [TIAtRisk|NatureStats]` + `[GeoBreakdown]`. **MUST-FIX #4:** GeoBreakdown **não** é full-width — usa `.chart-card` comum (1 col, `GeoBreakdown.js:38`) e não existe regra `wide`/`full` em `Dashboard.css`. DECISÃO: manter 9 cards com GeoBreakdown como orphan na linha 5; a alternativa (merge DETER Activity em HistoricalTrend para 8 cards, CONSIDER #1) foi descartada porque DETER é dataset distinto (km²/30d) e o orphan é visualmente aceitável.
  - **DETER Activity** — bar chart por classe (últimos 30 dias) de `/api/deter/stats` → `by_class`. Cores por classe: DESMATAMENTO_VEG=amber, CICATRIZ_DE_QUEIMADA=orange, DEGRADACAO=yellow, MINERACAO=red, outros=gray
  - **CAR Alerts Severity** — breakdown por severidade (maximo/alto/medio/baixo) da **rota nova** `/api/deter/car-alert-stats?days=7` (MUST-FIX #1 — ver arquivos de backend abaixo). **Não agregar client-side a partir de `/api/deter/car-alerts`**: a rota é paginada (page_size default 20 / max 100) e subestima quando há mais alertas. Cores: maximo=red, alto=orange, medio=amber, baixo=green
  - **Fire × Vegetation** — contexto agregado da **janela atual (~3 dias)** de `/api/fires?vegetation=true` (MUST-FIX #2: `get_fires` não tem parâmetro `days` — serve a janela atual `FIRMS_DAY_RANGE` ~3 dias com cap `MAX_RESULTS=10000`; "últimos 7 dias" é inalcançável sem agregado server-side — follow-up, CONSIDER #2). Contagem de fogos em vegetação nativa vs desmatada vs regeneração. 3 números grandes (ícones 🔥/🪓/🌱) ou bar chart
  - **SHOULD-FIX #1:** adicionar `deter_protected` ao `ALERT_TYPES` (`Dashboard.js:12`) — hoje tem só 6 tipos (indigenous_land, conservation_unit, cluster, night_fire, prodes, pm25) e o card "Alertas por categoria" subconta os alertas DETER em UCs
- Function(s): `Dashboard()` — 3 blocos de card no JSX + `useEffect`/`cachedFetch` para os 3 endpoints (TTL ~5min)
- Data shapes: `by_class: [{name, km2}]` (`/api/deter/stats`); `{total, by_severity: [{severity, count}], by_uf}` (`/api/deter/car-alert-stats`); fires com `vegetation: {status, year}` agregado client-side — **status usa prefixo `native`/`deforested`/`regrowth`** (SHOULD-FIX #4; `Home.js:252-254` testa `status.startsWith('deforested')`/`'regrowth'`), não "dYYYY/rYYYY"
- Integration points: `dash-body` grid (2-col); reutiliza `chart-card`/`bar-chart`/`chart-card__header` existentes
- Error paths: endpoint falha → card mostra empty state (`dash-loading`/`—`); sem dados → card vazio com mensagem; nenhum fetch quebra os cards existentes

##### backend-lua/app/routes/deter.lua
- What changes: **novo endpoint `get_car_alert_stats`** (MUST-FIX #1) — expor `db.get_car_alert_stats(days)` (**já existe** em `db.lua:1834`, retorna `{total, by_severity:[{severity,count}], by_uf}`) como `GET /api/deter/car-alert-stats?days=7`. Hoje `routes/deter.lua` só tem `get_polygons`/`get_stats`/`get_car_alerts` — a stats de severidade **não é rota**
- Function(s): `get_car_alert_stats` — auth.enforce + rl.enforce + parse_days com cap (espelhar `get_stats`, max 3650); retorna `{total, by_severity, by_uf}`
- Data shapes: `{total: number, by_severity: [{severity, count}], by_uf: [...]}`
- Integration points: registrada em `main.lua` (ver abaixo)
- Error paths: sem dados → `{total: 0, by_severity: [], by_uf: []}`

##### backend-lua/main.lua
- What changes: registrar `GET /api/deter/car-alert-stats` → `routes.deter.get_car_alert_stats` (junto das linhas 221-231, bloco `/api/deter/*`)
- Function(s): n/a (registro de rota)
- Data shapes: n/a
- Integration points: `routes/deter.lua` (ver acima)
- Error paths: n/a

##### frontend/src/i18n.js
- What changes: **novas chaves (CONSIDER #1)** — `dashboard.deterActivity`/`dashboard.deterActivityMeta`, `dashboard.carAlerts`/`dashboard.carAlertsMeta`, `dashboard.fireVegetation`/`dashboard.fireVegetationMeta`, mais labels de severidade (`dashboard.sevMaximo`/`sevAlto`/`sevMedio`/`sevBaixo`) e vegetação (`dashboard.vegNative`/`vegDeforested`/`vegRegrowth`) — blocos PT e EN
- Integration points: `useI18n` nos novos cards
- Error paths: n/a

##### frontend/src/components/Dashboard.css
- What changes: se as 3 séries precisarem de estilo novo (ex: 3 números grandes para Fogo×Veg), adicionar `.stat-grid`/`.stat-item`; reutilizar `bar-chart` onde possível
- Data shapes: CSS
- Error paths: n/a

#### Edge cases
- `/api/deter/stats` sem dados (região sem DETER) → bar chart vazio
- severidade sem alertas → 0 em todas as barras
- `/api/fires?vegetation=true` com volume alto → cachear com `ttl` (padrão `cachedFetch`); **o cap `MAX_RESULTS=10000` do `get_fires` é aceito para a janela atual (~3 dias)** — se o volume estourar o cap, o card mostra a contagem parcial (documentado) ou um agregado server-side (follow-up, CONSIDER #2)
- **Ordem de implementação: após Inc 3** — os 2 slots liberados pelo split do combo são preenchidos por DETER Activity e Fire×Vegetation; CAR Alerts Severity entra na linha seguinte (CONSIDER #2)

#### Verification
- Run: `cd frontend && npm run build`
- Visual: Dashboard com **9 cards** (8 em 4 linhas + GeoBreakdown orphan na linha 5), sem combo card, todos titulados, sem erros de console
- **CONSIDER #3:** capturar screenshot antes/depois (browser) para comparar a densidade do Dashboard
- Done: 3 cards novos renderizam com dados reais (local tem DETER/CAR/AMS populados pós-TerraBrasilis)

---

## Cross-cutting verification

Após todos os incrementos:
1. `make test-lua` — **176 testes passam** (20 arquivos `test_*.lua` + `helpers.lua`; contagem "83/83" defasada)
2. `cd frontend && npm run build` — sem erros nem warnings
3. Smoke test manual: Home → Dashboard → News → Mapas Temáticos, todas as páginas carregam sem erros de console (erros de console restantes no Mapas Temáticos vêm do iframe de terceiros `globalnaturewatch.org`, pré-existentes)
4. Dashboard com os 3 cards novos (Inc 6) — Fogo×Veg com dados reais (🔥 nativa / 🪓 desmatado / 🌱 regeneração); DETER Activity e CAR Severity com empty states corretos quando não há dados na janela
5. **Inc 6 (SHOULD-FIX #5):** `curl -H "X-API-Key: $API_KEY" "http://localhost:5001/api/deter/car-alert-stats?days=7"` retorna `{total, by_severity, by_uf}` — **rota nova registrada em `main.lua` + `routes/deter.lua`, testada em `test_deter_car.lua` (2 casos novos), backend reiniciado para carregar a rota**
6. `git diff --stat` — 18 arquivos alterados (687+/513-), 4 componentes deletados, 1 tool novo

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` existe com 6 lições; aplicadas:
  - **#1 (fixtures clock-relative):** `test_deter_car.lua` usa `days_ago(n)` nas fixtures da rota nova (`/api/deter/car-alert-stats`), nunca datas fixas.
  - **#2 (Redis isolado):** os testes de rota usam `fake_ctx` com `remote_addr=127.0.0.1` + stub do Redis (padrão `test_fires_routes.lua`); nenhum namespace de produção é escrito.
  - **#3 (batch, N+1):** nenhum loop per-item novo no backend; `get_vegetation_context_batch` já existente é reutilizado pelo card Fogo×Veg.

## Open questions (CONSIDER from review)

1. **Inc 5 pode ser splitado em dois**: (5a) infraestrutura do canvas + grid rendering básico; (5b) transição de zoom + polimento de performance. Como é o único incremento L, separar reduziria risco. Mantido como um só por enquanto; reavaliar se a implementação encontrar complexidade inesperada.
2. **Inc 2: confirmar que `satellite` permanece `useState(true)`** — intencional: o mapa deve começar com satélite + focos visíveis. PRODES/TI/UC são as camadas que começam desligadas.
3. **Inc 1: aplicar gsub antes da condição `#desc > #(current.description or "")`** — já especificado no plano ("antes da comparação de tamanho"). Garante que a lógica "keep longest" use texto limpo.
4. **Rollback do Inc 3 requer `git checkout` dos 4 arquivos** — diferente de mudanças aditivas, deleção de arquivo não tem toggle. O grep exaustivo mitiga; se algum componente for referenciado via lazy-load ou string ref, restaurar do git.
5. **FloatPanel** — auto-open **removido** (SHOULD-FIX #4): painel sempre colapsado, flag `loaded` no hero. Se no futuro reintroduzir auto-open, gatear com `userClosedRef` (setado no clique de fechar) para não reabrir contra a vontade do usuário.
6. **Título duplicado no início da description** — feeds Mongabay repetem o título ("PL de minerais... . Um novo projeto..."). O `strip_boilerplate` não remove esse prefixo. Follow-up possível (mais arriscado: requer comparação com title).
7. **Persistir toggles de camada em localStorage** — `showDeforest`/`showIndigenous`/etc. (padrão `setCacheSync` de News) para usuários recorrentes manterem a preferência; decisão de produto (CONSIDER #1).
8. **Grid: contagem por célula no hover** — exigiria reabilitar pointer-events + hit-testing no canvas; fora de escopo do Inc 5 (CONSIDER #2).
9. **Agrupamento das pílulas da layer bar** — 8 pílulas (pós-TerraBrasilis + TerraClass removido) é o teto aceito; agrupar CAR/CerradoVeg em "Imóveis & uso do solo" é follow-up se a barra pesar no mobile (SHOULD-FIX #2).
10. **Form de verificação PRODES (recibo CAR) no mapa** — chrome novo permanente abaixo da layer bar; colapsar atrás de uma ação ou manter visível? Decisão de produto (SHOULD-FIX #3).
11. **Densidade do popup de fogo** — 3 linhas de contexto (nature/vegetation/AMS) pode ser muito; compactar em uma linha única ou tooltip é follow-up (SHOULD-FIX #5).
12. **AMS × legenda de natureza compartilham matizes** — aceito (overlays sob demanda); revisitar se forem ligados juntos com frequência (CONSIDER #3).

## Out of scope

- Redesign completo da layer bar (dropdown "Camadas") — mantido como pílulas; agrupamento das 8 pílulas é follow-up
- Unificação total do sistema de cores dos dots — mantidos 2 sistemas com legenda aprimorada
- Alterações na Navbar (logo compacto) — fora do escopo deste plano
- Skeletons/loading states — já existem parcialmente; não abordados aqui
- Agregação server-side dos focos — o grid é puramente client-side
- Novos datasets/ingest — cobertos pelo plano TerraBrasilis (já concluído); este plano consome as APIs existentes (`/api/deter/*`, `/api/ams/*`, `/api/car/prodes`, `/api/fires?vegetation=true`) **e adiciona uma rota nova: `/api/deter/car-alert-stats` (Inc 6, MUST-FIX #1)**
