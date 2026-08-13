# CAR Highlight — indicador visual no "Verificar imóvel"

## Context

Quando o usuário usa a feature **"Verificar imóvel"** (recibo CAR → PRODES),
o mapa voa até o imóvel via `map.flyToBounds` (`ProdesFlyTo`, `Home.js`), mas
não há nenhum indicador visual apontando **qual** polígono CAR é o alvo — o
overlay CAR é um raster de tiles (`#FF84FF` magenta) e todos os imóveis ao
redor ficam igualmente pintados.

**Intended outcome:** ao verificar/selecionar um imóvel, desenhar um contorno
(highlight) do polígono exato daquele CAR **por cima** do overlay raster,
seguindo o padrão visual das TIs/UCs (contorno tracejado) mas na cor do CAR e
mais forte, para o imóvel alvo se destacar imediatamente.

User-confirmed decisions (Step 3 question gate):
- **Highlight do polígono exato** (não um retângulo de bbox) — exige expor a
  geometria do backend.
- **Novo endpoint leve `/api/car/geometry`** (não estender o payload do
  `/api/car/prodes`), mantendo o cache Redis de 24h do prodes enxuto.
- **Disparo:** a cada resultado de verificação + ao abrir o resumo pelo popup
  de CAR ("Ver resumo do imóvel"). **Limpeza:** ao fechar o card de resultado.
- **Estilo:** contorno tracejado em `CAR_COLOR` (`#FF84FF`), mais forte
  (maior weight/fill) que TIs/UCs.

> **Atualização pós-implementação (2026-08-13):** o usuário pediu para alinhar
> o highlight ao tom das TIs/UCs — linhas finas e mesma opacidade. `CAR_HIGHLIGHT_STYLE`
> agora é `weight: 1.25, opacity: 0.85, fillOpacity: 0.08, dashArray: '5 4'`
> (idêntico ao padrão TI/UC, só muda a cor). O `BiomeHighlightLayer` (que ainda
> estava no padrão antigo `weight: 2.5, fillOpacity: 0.18, opacity: 0.9`) também
> foi alinhado para `weight: 1.25, fillOpacity: 0.08, opacity: 0.85`.

## Architectural decisions

- **Decision: geometria exata via novo endpoint dedicado.** `get_by_cod_imovel`
  já retorna `geom` (GeoJSON text) + `bbox` (`car_lookup.lua:143-181`); o
  `/api/car/geometry?cod_imovel=...` expõe esse `geom`. Rationale: o payload do
  `/api/car/prodes` é cacheado 24h no Redis e ficaria pesado com a geometria
  inteira de imóveis grandes; um endpoint separado permite cache longo próprio
  e não contamina o cache de verificação. Alternatives rejected: estender
  `/api/car/prodes` (acoplamento cache/payload); endpoint de bbox (não destaca
  a forma real do polígono).
- **Decision: frontend consome a geometria e desenha via `L.geoJSON`
  destacado.** Clonar o padrão `BiomeHighlightLayer` (`Home.js:905`): filho do
  `MapContainer` que monta/remove um `L.geoJSON` no `useMap()`, `interactive:
  false`, e voa até o bbox. Estilo baseado no `INDIGENOUS_STYLE`/`CONSERVATION_STYLE`
  (tracejado `dashArray:'5 4'`) porém com `weight` e `fillOpacity` maiores e
  cor `CAR_COLOR`. Rationale: reusa o template já validado e não toca no
  `ProdesFlyTo` (que continua só voando); o highlight fica em camada própria
  acima dos tiles (zIndex).
- **Decision: cache do endpoint de geometria com TTL longo.** A geometria de um
  `cod_imovel` é estática por ingest; `cachedFetch` com TTL 24h+ (como
  indigenous/conservation, 1h+). Não cachear por clique no ponto (path de
  `onCarInspect` usa `fetch` puro); o highlight usa o `cod_imovel` do
  resultado, que é estável.
- **Decision: highlight derivado do estado do card, não do fly.** O estado
  `carHighlight` (geometria do imóvel ativo) é setado quando `prodesResult`
  chega com sucesso (verify ou `loadCarSummary`) e limpo no `clearProdes` E no
  início de cada nova `prodesQuery` (para um verify subsequente que retorne
  `not_found`/`car_unavailable` não deixar o contorno do imóvel anterior na
  tela). Um componente `CarHighlightLayer` recebe a geometria e monta o contorno.
- **Decision: guarda de troca rápida compara com o `cod_imovel` do resultado
  ATUAL via ref, não com o `cod` local da invocação.** O padrão do
  `protected-overlap` compara com o `cod` local (closure daquela invocação), o
  que deixaria uma resposta atrasada do código A passar quando B é o atual.
  Usar um `prodesResultRef` atualizado a cada render para comparar o
  `cod_imovel` da resposta de geometria contra o resultado vigente.
- **Decision: rota registrada em `main.lua` espelhando `/api/car/summary`**
  (auth + rate-limit), handler `get_geometry(ctx)` em `app/routes/car.lua`.

## Assumptions and answers from code

- Decision: `get_by_cod_imovel` retorna `geom` (GeoJSON text) e `bbox` — code @
  `backend-lua/app/lookups/car_lookup.lua:173-180`. `geom` é `json(geom)` (texto
  GeoJSON), pronto para `cjson.decode` no cliente ou repassar como string.
- Decision: padrão de rota/registro — code @ `backend-lua/main.lua:212-215`
  (`/api/car/summary`) e `backend-lua/app/routes/car.lua:456` (`get_summary`).
- Decision: template de highlight — code @ `frontend/src/components/Home.js:905-960`
  (`BiomeHighlightLayer`); estilos TI/UC @ `Home.js:874-875`; `CAR_COLOR` @
  `Home.js:890`.
- Decision: `clearProdes` limpa o resultado — code @ `Home.js:998-1003`;
  `prodesQuery` seta `prodesResult` @ `Home.js:1013-1014`; `loadCarSummary` reusa
  `prodesQueryRef` @ `Home.js:1106-1121`.
- Decision: `cachedFetch` (dedup+TTL) — code @ `frontend/src/utils/apiCache.js`.
- Decision: sem harness de teste frontend; backend testado via Busted com fake
  ctx + fixture `car_sample.json` (3 imóveis) — code @ `backend-lua/tests/test_car_routes.lua`.
- Decision (user-confirmed): estilo tracejado na cor do CAR, mais forte que
  TI/UC.

## Risks accepted

- **Imóvel grande / geometria pesada no payload do novo endpoint:** o
  `geom` de um imóvel pode ter milhares de pontos. Mitigação: endpoint
  dedicado (não no prodes), e o Leaflet consegue desenhar polígonos de
  milhares de vértices sem problema perceptível; aceitar; revisit if um imóvel
  específico travar (poderia simplificar `tolerance` server-side). Adicionar um
  `logger.warn` quando a geometria for grande (espelhando o `car/prodes slow
  path` em `car.lua:120`) para observabilidade.
- **Cache de geometria estale após re-ingest:** o `cachedFetch` é um Map em
  memória por carregamento de página (não persiste entre reloads) e NÃO
  invalida em runtime, então a geometria é refetchada a cada page load e o
  TTL longo só deduplica dentro da mesma sessão. Como ingest CAR é offline,
  aceitamos que uma sessão longa possa reter geometria pré-ingest até o
  TTL (24h) expirar. Não introduzimos cache no Redis para geometry
  (diferente do prodes).
- **Falha do endpoint de geometria:** highlight silenciosamente ausente, o
  fly-to (bbox) já existente continua funcionando. Não bloquear o resultado do
  prodes.

## Increment DAG

- Inc 1 — Backend: rota `/api/car/geometry` (S) — depends on: none — unblocks: 2, 3
- Inc 2 — Frontend: highlight por verificação + popup + limpeza (M) — depends on: 1
- Inc 3 — Backend: teste Busted da rota geometry (S) — depends on: 1

## Increments

### Inc 1 — Backend: rota `/api/car/geometry` (S) ✅ done
**Depends on:** none
**Unblocks:** 2, 3
**Done criteria:** `curl /api/car/geometry?cod_imovel=<fixture>` retorna o
`geom` (GeoJSON) + `bbox` do imóvel; `404/200 not_found` para código inexistente.

#### Files to touch

##### backend-lua/app/routes/car.lua
- What changes: nova função `get_geometry(ctx)` espelhando `get_summary`
  (linha 456): auth + rate-limit, valida `cod_imovel`, `car.load_car()`,
  `car_lookup.get_by_cod_imovel(cod)`, retorna `{ cod_imovel, found, geom, bbox }`.
- Function(s):
  ```lua
  function _M.get_geometry(ctx)  -- GET /api/car/geometry?cod_imovel=...
  ```
- Data shapes:
  - Success: `{ cod_imovel = prop.id, found = true, geom = prop.geom, bbox = prop.bbox }`
    (`geom` é texto GeoJSON; `bbox` é `{min_lon,min_lat,max_lon,max_lat}`).
  - Not found: `{ cod_imovel = cod, found = false, reason = "not_found" }`.
  - CAR unavailable: `{ cod_imovel = cod, found = false, reason = "car_unavailable", note = "CAR unavailable" }`.
  - 400: `{ error = "Missing cod_imovel" }`.
- Integration points: registrado em `main.lua` (Inc 1b); chamado pelo frontend
  em Inc 2.
- Error paths:
  - `prop == nil` → `{ found=false, reason="not_found" }`.
  - `car.is_loaded() == false` → `{ found=false, reason="car_unavailable" }`.
  - `geom` ausente/string vazia/`"null"` → `{ found=false, reason="not_found" }`.
    O `json(geom)` de uma coluna JSONB vazia retorna o literal `"null"`, que
    deve ser tratado como inexistente.
- Note: NÃO decodificar/re-encode `geom` no servidor — repassar o texto
  GeoJSON para o cliente evitar custo CPU no event loop (single-threaded).
  Verificar apenas que a string existe e não é `"null"`.
- Note (shape): o endpoint retorna top-level `{ cod_imovel, found, geom, bbox }`
  (espelhando `get_summary`), NÃO o wrapper `{ ok, cached, data }` do prodes.
  Desvio intencional e documentado — o frontend lê `g.geom`/`g.bbox` no topo.
  Não "consertar" para o shape do prodes sem atualizar o consumidor.
- Observability: adicionar `logger.warn` se `string.len(prop.geom)` exceder
  um limite (sugestão: 100 KB de texto GeoJSON ou ~5.000 vértices), espelhando
  o `car/prodes slow path` (`car.lua:120`). Usar `string.len` como proxy
  inicial; a contagem exata de vértices exigiria parse.

##### backend-lua/main.lua
- What changes: registrar rota `GET /api/car/geometry`.
- Integration points: após `/api/car/summary` (~linha 212-215):
  ```lua
  server.route("GET", "/api/car/geometry", function(ctx)
      local car_routes = require("app.routes.car")
      car_routes.get_geometry(ctx)
  end)
  ```

#### Edge cases
- `cod_imovel` vazio/não-string → 400.
- Imóvel existente mas row sem `g` → `not_found` (nunca 500).
- Não adicionar cache Redis (geometria pode ser grande; TTL do cliente é suficiente).

#### Verification
- Run: `curl -s 'http://localhost:5000/api/car/geometry?cod_imovel=MA-2100436-A5076E18F7174972A79EB3C7802D40DC'`
  → `found:true` com `geom`/`bbox`.
- Tests to add/update: Inc 3.
- Done: resposta com `geom` válido.

---

### Inc 2 — Frontend: highlight por verificação + popup + limpeza (M) ✅ done
**Depends on:** 1
**Unblocks:** —
**Done criteria:** ao verificar um imóvel (form ou "Ver resumo do imóvel" do
popup), o contorno tracejado magenta do polígono aparece sobre o mapa e o mapa
voa até ele; fechar o card remove o contorno.

#### Files to touch

##### frontend/src/components/Home.js
- What changes:
  1. Novo estado `carHighlight` (geometria do imóvel ativo) em `MapaCard`.
  2. Buscar `/api/car/geometry` quando `prodesResult` chega com sucesso
     (`found:true`), via `cachedFetch` (TTL longo, ex. 24h).
  3. Novo componente `VerifiedCarHighlightLayer` (clone de
     `BiomeHighlightLayer`) montado dentro do `<MapContainer>`: recebe a
     geometria, monta um `L.geoJSON` (estilo tracejado CAR) e `flyToBounds`
     no bbox.
  4. Limpar `carHighlight` no `clearProdes`.
  5. Novo style const `CAR_HIGHLIGHT_STYLE`.
- Function(s):
  ```js
  const CAR_HIGHLIGHT_STYLE = {
    color: CAR_COLOR, fillColor: CAR_COLOR,
    fillOpacity: 0.14, weight: 3, opacity: 1, dashArray: '5 4',
  };
  function CarHighlightLayer({ geometry, bbox }) { /* useMap(); L.geoJSON; addTo/remove; flyToBounds */ }
  ```
- Data shapes:
  - `carHighlight` state: `{ geom: <GeoJSON object>, bbox: <{min_lat,...}> } | null`
    (decodificar o texto `geom` do endpoint com `JSON.parse`).
  - `CarHighlightLayer` props: `{ geometry, bbox }`.
- Integration points:
  - No início de `prodesQuery` (junto a `setProdesError(null)`/`setProtectedOverlap(null)`,
    linha ~1008): adicionar `setCarHighlight(null)` — toda nova verificação
    reseta o highlight ANTES do fetch resolver, para um verify subsequente que
    retorne `not_found`/`car_unavailable` não deixar o contorno do imóvel
    anterior na tela.
  - Após `setProdesResult(d)` em `prodesQuery` (linha ~1014), se `d.data?.found`:
    `cachedFetch('/api/car/geometry?cod_imovel=...', { ttl: 86_400_000 })`
    → se `g && g.found && g.geom` (guarda explícita, não depender do try/catch)
    e `g.cod_imovel === prodesResultRef.current?.data?.cod_imovel` (guarda de
    troca rápida contra o resultado VIGENTE, não o `cod` local):
    `setCarHighlight({ geom: JSON.parse(g.geom), bbox: g.bbox })`.
  - `clearProdes` (linha ~998): adicionar `setCarHighlight(null)`.
  - Manter um `prodesResultRef` atualizado a cada render (ou no `setProdesResult`)
    para a guarda de troca rápida comparar contra o resultado atual.
  - Montar `<VerifiedCarHighlightLayer geometry={carHighlight?.geom} bbox={carHighlight?.bbox} />`
    dentro do `<MapContainer>` junto ao `<ProdesFlyTo>` (linha ~1451).
  - `loadCarSummary` já reusa `prodesQuery` → o highlight dispara automaticamente
    para o path do popup. Nenhuma mudança extra ali.
- Error paths: falha do fetch de geometria → não seta `carHighlight` (highlight
  ausente, fly-to bbox continua). `JSON.parse` em `geom` inválido → try/catch,
  não derruba o resultado. `g.found === false` (imóvel sumiu entre prodes e
  geometry) → não seta highlight.

#### Edge cases
- Imóvel não encontrado / `car_unavailable` → `d.data.found === false`, não setar
  highlight; e o `setCarHighlight(null)` no início de `prodesQuery` garante que
  um contorno anterior é limpo.
- Troca rápida de código: resposta de geometria de um código anterior não pode
  vazar para o card novo — comparar `g.cod_imovel` contra o `cod_imovel` do
  resultado VIGENTE via `prodesResultRef` (NÃO o `cod` local da invocação, que
  deixaria a resposta atrasada de A passar quando B é o atual).
- `bbox` ausente → `flyToBounds` opcional (usa `geometry` bounds se disponível).
- Z-order: chamar `layer.bringToFront()` no `useEffect` após `layer.addTo(map)`;
  o efeito deve depender de `showIndigenous`/`showConservation` (re-executar
  `bringToFront()` quando esses toggles mudarem), para que o contorno do imóvel
  verificado fique sempre acima dos overlays vetoriais TI/UC, independente da
  ordem de montagem.
- Mobile: o highlight é uma camada do mapa (não do sheet) → funciona igual no
  mobile e desktop; nada a mudar no `FloatPanel`.

#### Verification
- Run: `npm start` (ou build) em `frontend/`; verificar via UI no navegador.
- Tests to add/update: nenhum (sem harness frontend).
- Done: verificar imóvel → contorno magenta tracejado visível sobre o overlay
  CAR; fechar card → some.

---

### Inc 3 — Backend: teste Busted da rota geometry (S) ✅ done
**Depends on:** 1
**Unblocks:** —
**Done criteria:** `busted backend-lua/tests/test_car_geometry.lua` passa.

#### Files to touch

##### backend-lua/tests/test_car_geometry.lua (novo)
- What changes: espelhar `test_car_routes.lua` (fake ctx, fixture
  `car_sample.json`, `CAR_DB_PATH` temporário, re-require). Testar
  `car_routes.get_geometry(ctx)` com o fake ctx.
- Function(s): blocos `describe/it` padrão Busted.
- Data shapes: assert no `ctx.body`:
  - `found == true`.
  - `geom` é string não-vazia, `cjson.decode(geom)` tem `type == "Polygon"|"MultiPolygon"`.
  - `bbox` contém exatamente `{ min_lon, min_lat, max_lon, max_lat }` com
    `min_lon < max_lon` e `min_lat < max_lat`.
- Integration points: mesmo setup de fixture de `test_car_routes.lua`; usar
  `days_ago`/helpers se precisar de datas (aqui não precisa — geometria estática).
- Error paths: `get_geometry` com `cod_imovel` vazio → 400; com código inexistente
  → `found:false, reason:"not_found"` (status 200, como prodes). Sem vazamento
  de Redis (não usa Redis).

#### Edge cases
- Fixture tem exatamente 3 imóveis (`car_sample.json`) — usar um `cod_imovel`
  conhecido da fixture para o sucesso; um inventado para `not_found`.
- Garantir teardown: remover `tmp_car_db` no `after_all` (mesmo padrão dos
  testes existentes).

#### Verification
- Run: `cd backend-lua && busted tests/test_car_geometry.lua` (ou
  `make test-lua`).
- Tests to add/update: este arquivo novo.
- Done: suíte verde, sem vazamento de arquivos temporários.

## Cross-cutting verification

- Após Inc 2 + 3: no navegador, (a) digitar um recibo CAR na aba "Verificar
  imóvel" → mapa voa e contorno magenta tracejado do polígono exato aparece;
  (b) clicar num CAR no mapa → popup → "Ver resumo do imóvel" → highlight
  aparece; (c) fechar o card de resultado → contorno some; (d) no mobile o
  highlight aparece igual (camada do mapa); (e) verificar um código válido e
  depois um inexistente → o contorno do primeiro some quando o card de
  "não encontrado" aparece; (f) verificar A e rapidamente B → o contorno
  mostrado é o de B, nunca o de A (troca rápida). Confirmar que o contorno
  fica ACIMA do overlay de tiles CAR e dos overlays vetoriais TI/UC (z-order)
  e não some ao dar zoom.

## Standards / common-mistakes referenced
- `.agents/common-mistakes/common-mistakes.md` #7 — react-leaflet v4 Popup:
  o highlight é uma camada separada, NÃO um popup; não depende do lifecycle
  do popup.
- Design tokens (`--signal` etc.): usar `CAR_COLOR` (#FF84FF) como fonte única
  de cor do CAR; nenhuma cor ad-hoc.
- Sem `backdrop-filter`/drop-shadow (memória repo mobile-bottom-sheet): o
  highlight é um path do Leaflet (stroke/fill), sem elevação de painel.

## Open questions (CONSIDER from review)
- A lógica de set/clear do highlight é inteiramente sem harness de teste
  frontend. Considerar extrair a decisão "devo setar/limpar o highlight" numa
  função pura (ex. `shouldApplyHighlight(prodesResult, geometryResp, currentCod)`)
  testável, ou ao menos cobrir os casos de troca rápida e not-found no checklist
  manual de verificação.
- O TTL de 24h do `cachedFetch` é só em memória (por page load) e não invalida
  em runtime; o framing de "cache longo" superestima o benefício cross-session,
  mas é aceito porque o endpoint é barato e ingest CAR é offline.
- O teste `test_car_geometry.lua` pode acabar exercitando o fallback
  `geom_bbox` se o fixture não tiver `car_rtree` populado. Documentar no teste
  qual caminho está sendo testado para evitar surpresas.

## Out of scope
- Interatividade do highlight (hover/click no contorno, popup no highlight).
- Simplificação geométrica (tolerance) server-side.
- Estender o payload do `/api/car/prodes` com geometria.
- Harness de testes frontend.
