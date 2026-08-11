# Mobile UI Refactor — Unified Bottom Sheet

## Contexto

O app Yvy (observabilidade ambiental) tinha três pontos de entrada de painel no
mobile — **Verificar Imóvel** (PRODES check por recibo CAR), **Sobreposições** e
**Natureza do Fogo** — implementados como três modais independentes com
posições de ancoragem diferentes (FAB esquerdo, pills à direita). Isso quebrava
a consistência visual e criava múltiplas camadas flutuantes sobre o mapa.

## Objetivo

Consolidar os três modais num **bottom sheet único com abas internas**, ancorado
à barra de alertas (`397 ALERTAS`), e aplicar os tokens do design system
(`.agents/DESIGN.md`) em todos os componentes flutuantes do mobile.

## Decisões de arquitetura

O `FloatPanel` existente já era, no mobile, uma barra de alertas colapsada
(contagem + unidade "alertas") que expandia como bottom sheet com abas
ALERTAS/BIOMAS/CLIMA. Em vez de criar um componente novo concorrente, **estendemos
o `FloatPanel`** para ser o único bottom sheet:

- **Colapsado**: só a barra de alertas (contagem `data-large`, badges `data-small`).
- **Expandido**: abas internas `ALERTAS / BIOMAS / CLIMA / SOBREPOSIÇÕES / NATUREZA
  DO FOGO / VERIFICAR IMÓVEL`, com scroll horizontal na barra de abas.
- Trocar de aba é troca de conteúdo interno — o sheet não fecha/reabre.

Os três modais antigos deixaram de existir como camadas flutuantes:
- **Sobreposições** → aba `overlays` (4 linhas PRODES/TI/UC/CAR com dim state).
- **Natureza do Fogo** → aba `nature` (legenda Fire Data Encoding + período).
- **Verificar Imóvel** → aba `verify` (form PRODES + resultado/erro).

Desktop fica **intocado** (fora de escopo): continua com os 3 modais/legendas
posicionados separadamente.

## Mapeamento prompt → código real

| Prompt (genérico)          | Código real                         |
|----------------------------|-------------------------------------|
| `VerificarImovelModal`     | `.prodes-check` (PRODES por recibo) |
| `SobreposicoesModal`       | `.overlays-legend`                  |
| `NaturezaDoFogoModal`      | `.nature-legend`                    |
| Barra "466 ALERTAS"        | `float-panel` colapsado (`fp-summary`) |

## Implementação

### `frontend/src/components/Home.js`
- `MOBILE_TABS = ['alerts','biomes','clima','overlays','nature','verify']`.
- `FloatPanel` recebe prop `verify` (fragments JSX dos ex-modais) e monta as abas.
- Content fragments definidos no pai (`MapaCard`): `overlaysRows`,
  `natureLegendBody`, `prodesForm`, `prodesResultBody`.
- `FIRE_NATURE_COLORS` → paleta Fire Data Encoding:
  crime=`#C62828` (ember-high), suspeito=`#FF6200` (ember-mid),
  permitido=`#00C97A` (signal), natural=`#8A9E93` (ink-muted).
- Drag handle: `pointerdown/move/up` no `.fp-handle` colapsa após >60px para baixo
  (touch-only, `pointerType !== 'mouse'` para não conflitar com scroll interno).
- Backdrop `.fp-backdrop` sobre o mapa quando o sheet abre (tap fora colapsa).
- Removidos states mortos `showMobileProdes` / `showMobileLegend`.

### `frontend/src/index.css`
- Tokens do design system como variáveis CSS: `--canvas`, `--surface-100/200/300`,
  `--border`, `--signal`, `--signal-dim`, `--ink`, `--ink-muted`, `--ink-faint`,
  `--ember-low/mid/high`, `--alert-ring`, + roles tipográficos `--type-*`.

### `frontend/src/Home.css`
- Removido todo CSS morto dos modais mobile (`--mobile`, `nature-legend-card`, etc.).
- `backdrop-filter`/glass removido de painéis e popups — elevação via `border`.
- `.float-panel--mobile`: fundo `--surface-100`, borda `--border`, sem shadow.
- `.fp-tabs--mobile`: `overflow-x:auto` + mask fade.
- `.fp-tab`: `flex-shrink:0` (nenhum item cortado).
- `.layer-toggle` / `.days-chip`: estados pill ativo (`surface-300`+`signal`+
  `signal-dim`) / inativo (`surface-100`+`ink-muted`+`border`).
- `.fp-count` (data-large), `.fp-badge` (data-small) tabular.
- `.days-chips`: `flex-wrap:nowrap` + `overflow-x:auto` + fade.

### `frontend/src/i18n.js`
- Adicionados `expandLegend` / `collapseLegend` (PT/EN) — antes eram keys soltas.

## Critério de aceite (verificado)

- Mobile (~400px): abrir cada aba — todas nascem do mesmo bottom sheet ancorado;
  sem modais soltos no topo/meio. ✅
- Nenhum painel usa cor/opacidade/blur fora dos tokens. ✅
- Chips rolam horizontalmente sem cortar o último. ✅
- No máximo 2 camadas flutuantes (mapa + 1 sheet). ✅
- Desktop intocado (3 abas, legendas separadas). ✅

## Follow-ups (2026-08-11)

- **Glass nos toggles de camada**: restaurado `backdrop-filter: blur(12px)` +
  fundo translúcido nos `.layer-toggle` (desktop e mobile).
- **Ordem das abas do sheet**: `ALERTAS / BIOMAS / SOBREPOSIÇÕES / FOCOS / CLIMA /
  VERIFICAR IMÓVEL` (CLIMA e FOCOS invertidos).
- **Renome**: "Natureza do fogo" → "Focos" (PT) / "Fire nature" → "Fires" (EN).
- **Toggle CAR** movido para logo após Desmatamento na barra de camadas.
- **Sobreposições** reposicionado para o canto superior direito (top:60px,
  right:16px), alinhado com "Verificar imóvel". Largura expandida 224px
  (acomoda "Cadastro Ambiental Rural"), colapsada 172px (título + chevron).
- **Verificar imóvel** reduzido para 255px.
- **Bug de zoom no overlay CAR**: tiles pré-computados só existem em z6–14, mas
  o frontend pedia z2–5 (minZoom=2) → CAR sumia de longe. Fix: `minNativeZoom={6}`
  no TileLayer CAR faz o Leaflet pedir z6 e escalar. Backend ganhou fallback de
  descendente (`lookup_descendant`) como rede de segurança.

## Fora de escopo
- Lógica de dados/API (só camada de apresentação).
- Mover "Sobreposições" pro canto superior direito no desktop (tarefa separada).
- Novas bibliotecas de UI.
