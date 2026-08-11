# Overlay Legend Card (right-side, symmetric to float panel)

## Context

The map exposes 4 toggleable geo-data overlays in the layer bar:
**Desmatamento (PRODES)**, **Terras Indígenas (TI)**, **Unid. Conservação (UC)**,
**CAR**. The user already understands their effect (they can see the polygons
appear/disappear), but there is no on-screen reference for **which color encodes
which layer** while all of them are on simultaneously.

The existing `.nature-legend` card (bottom-left, `Home.js:1475-1576`) is the
template: dark glass panel, hairline border, panel-header title, dot+label rows.
It answers the same question for the fire nature/confidence encodings.

This plan adds the symmetric counterpart for the overlay layers: a card anchored
to the same right-side column as the existing `float-panel` (`ALERTAS AO VIVO`),
stacked above it, sharing the same panel chrome (width 272px, border-radius
12px, background 0.93, border `rgba(42,53,48,1)`, panel-header typography).
The card has a header + chevron (mirroring `.fp-summary` / `.fp-chevron`) that
collapses/expands the swatch list.

Intended outcome: a user can glance at the legend and know which color is TI vs
UC vs CAR vs PRODES without having to toggle layers off one at a time to
identify them.

## Assumptions and decisions

- Decision: **Position is a stacked card above the float panel**, sharing the
  same `right: 20px` anchor. Source: user-confirmed (Q1).
- Decision: **Content is exactly 4 rows** — PRODES, TI, UC, CAR. Focos is
  excluded (it has its own legend on the opposite side). Satélite is excluded
  (no color, swaps base tile). Source: user-confirmed (Q2).
- Decision: **All 4 rows are always shown**, with `opacity: 0.35` on rows
  whose layer is currently off (mirrors `.nature-legend`'s `ink-muted` /
  `ink-faint` hierarchy for "available but not active"). Source:
  user-confirmed (Q3).
- Decision: **Header + chevron collapse pattern**, mirrors `float-panel`'s
  `.fp-summary` (line 497) + `.fp-chevron` (line 558). Default state:
  **expanded on desktop, collapsed on mobile** (so the mobile first paint is
  the compact pill, not a horizontal strip of labelled boxes). Source:
  user-confirmed (Q4) + derived from review of mobile state behavior.
- Decision: **Card width = 272px** (matches `.float-panel` width 272px at
  `Home.css:486`). Reason: user asked for strict symmetry. The visual column
  on the right is now a true stack of two same-width cards.
- Decision: **Border-radius = 12px** (matches `.float-panel`). The
  `.nature-legend` template uses 10px because it's a smaller standalone
  panel; the float panel is the canonical "right-side card" template.
- Decision: **Swatch shape = 8×8px circle** (matches `.nature-legend-dot`,
  `Home.css:452-457`). Reason: user asked for strict style match; the
  "polygon vs point" semantic argument is rejected in favor of stylistic
  consistency with the existing legend.
- Decision: **PRODES swatch color = `#C62828`** (the literal value of
  `--ember-high`, `DESIGN.md:14`). The PRODES tile layer is a raster served
  at 33% opacity — there is no inline stroke color to read from code; the
  swatch represents the data encoding, not a UI accent. The design system's
  "no ember outside map/alert" rule's intent is to prevent ember from
  appearing in *non-data* UI chrome (borders, backgrounds, buttons); a
  legend swatch is a data legend, which is the same exception the design
  system already grants to the float panel's "alerts" severity indicator.
  Source: derived from `Home.js:1348-1354` (PRODES is a `TileLayer` with no
  inline color) + `DESIGN.md:Do's-and-Don'ts`.
- Decision: **Card `bottom: 92px`** — pairs above the COLLAPSED float
  panel with a ~20px gap (20px panel bottom + ~52px collapsed summary
  height + 20px gap). User-confirmed override (Q5) over the original
  `bottom: 460px` plan value, which was arithmetically wrong (it only
  counted the 420px body, missing the 44px+ summary, and left a ~440px
  gap when the float panel was collapsed). When the float panel is
  EXPANDED (z-index 450 > 440) it paints over the legend — the user
  accepted this (they inspect alerts OR overlays, not both).
- Decision: **Card `z-index: 440`**, below `.float-panel` (450). The float
  panel paints on top of the overlays-legend when expanded (per Q5), and
  the chevron arrow / close affordances on the float panel are never
  occluded.
- Decision: **Mobile `bottom: 104px`** — above the nature-legend mobile
  toggle, which occupies `bottom: 58px`–`98px` (`Home.css:912-916` has the
  toggle at `bottom: 58px` with ~40px min-height). The original plan value
  `bottom: 80px` would collide with that toggle (58–98px band).
- Decision: **Mobile variant**: when `isMobile` is true on first mount the
  card starts collapsed (compact pill showing 4 colored dots in a row);
  tap to expand. When the user resizes from desktop to mobile, the existing
  open/closed state is preserved (the state is a useState that runs once).
  Source: matches `.nature-legend--mobile` behavior (`Home.css:909-1019`).
- Decision: **Chevron = lucide `ChevronDown` icon** (already imported at
  `Home.js:3`), same as the float panel's chevron (`Home.js:643`). Uses
  `className="overlays-legend-chevron"` with the same
  `transform: rotate(180deg)` open state as `.fp-chevron--open`
  (`Home.css:559`). Color = `rgba(138,158,147,1)` = `--ink-muted` (same as
  `.fp-chevron`). (Correction: the original plan said "`▾` text glyph" —
  the float panel actually uses the lucide icon, so the legend uses the
  same icon for strict symmetry.)
- Decision: **Touch target min-height: 44px** on the summary button to
  match `.fp-summary` (`Home.css:511`).
- Decision: **i18n key `home.overlaysLegend`** added in PT (`Sobreposições`)
  and EN (`Overlays`). Insertion point: near the existing legend keys —
  PT line ~82-89 (after `natureLegend`), EN line ~277-284 (after
  `natureLegend`).
- Decision: **Constant name: `PRODES_OVERLAY_COLOR`** (canonical
  "PRODES-on-map" color, reusable beyond the legend). Not
  `PRODES_LEGEND_COLOR` — the constant is the overlay's encoded color, the
  legend just happens to use it.

## Files to touch

### `frontend/src/components/Home.js`

- **What changes**: add JSX for the new card after the float panel; add one
  local state for collapse; add one module-scope constant for PRODES color.
- **Constant added** (top of file with the other style constants, near
  `Home.js:806-816`):
  ```js
  // PRODES tile layer is a raster served at 33% opacity (Home.js:1348-1354)
  // with no inline color; the swatch represents the data encoding. The
  // color matches the high end of the design-system ember gradient so
  // the legend reads the same as the rendered map.
  const PRODES_OVERLAY_COLOR = '#C62828';
  ```
- **State added (inside `MapaCard`)**:
  ```js
  // Default: expanded on desktop, collapsed on mobile (the mobile variant
  // is a compact pill; expanded-on-mobile would be a horizontal strip of
  // 4 labelled boxes on first paint).
  const [showOverlaysLegend, setShowOverlaysLegend] = useState(!isMobile);
  ```
- **JSX added** (positioned between the closing of `.prodes-check` and
  the closing of `.map-stage`; the exact neighborhood in
  `Home.js:1580-1620` — insertion goes just before the map-stage closing
  `</div>` so the legend is a sibling of the float panel inside the same
  `position: relative` container):
  ```jsx
  <div
    className={
      'overlays-legend'
      + (showOverlaysLegend ? ' overlays-legend--open' : '')
      + (isMobile ? ' overlays-legend--mobile' : '')
    }
  >
    <button
      type="button"
      className="overlays-legend-summary"
      onClick={() => setShowOverlaysLegend(o => !o)}
      aria-expanded={showOverlaysLegend}
    >
      <span className="overlays-legend-title">{t('home.overlaysLegend')}</span>
      <span className="overlays-legend-chevron" aria-hidden="true">▾</span>
    </button>
    {showOverlaysLegend && (
      <div className="overlays-legend-rows">
        {[
          { key: 'prodes', label: t('home.layerDeforestation'),  color: PRODES_OVERLAY_COLOR,    on: showDeforest },
          { key: 'ti',     label: t('home.layerIndigenous'),    color: INDIGENOUS_STYLE.color,  on: showIndigenous },
          { key: 'uc',     label: t('home.layerConservation'),  color: CONSERVATION_STYLE.color, on: showConservation },
          { key: 'car',    label: t('home.layerCar'),           color: CAR_COLOR,                on: showCar },
        ].map(({ key, label, color, on }) => (
          <span
            key={key}
            className={'overlays-legend-row' + (on ? '' : ' overlays-legend-row--off')}
          >
            <span
              className="overlays-legend-swatch"
              style={{ background: color }}
            />
            <span className="overlays-legend-label">{label}</span>
          </span>
        ))}
      </div>
    )}
  </div>
  ```
- **Integration points**:
  - Reads `showDeforest`, `showIndigenous`, `showConservation`, `showCar`,
    `isMobile` — all in scope of `MapaCard` (`Home.js:902-1600`).
  - Uses `INDIGENOUS_STYLE.color`, `CONSERVATION_STYLE.color`, `CAR_COLOR`
    already defined at module scope.
  - Renders as a sibling of the float panel inside `.map-stage`; absolute
    positioning is relative to the map stage (which is `position:
    relative`, set in `Home.css`).
- **Error paths**: none — purely declarative rendering, no fetches, no async.

### `frontend/src/Home.css`

- **What changes**: add a new section at the end of the file (after the
  nature-legend mobile section, `Home.css:1019-1023`) with the new
  `.overlays-legend-*` rules. Numeric values mirror `.float-panel` /
  `.fp-summary` / `.fp-chevron` so the card is visually identical to the
  panel it pairs with.
- **Rules to add**:
  ```css
  /* ── Overlays legend (right side, stacked above float panel) ──────── */
  .overlays-legend {
    position: absolute;
    right: 20px;
    bottom: 460px;          /* float panel: 20px bottom + max-height 420px
                               (Home.css:561) + 20px gap. Anchors the card
                               above the float panel's expanded footprint. */
    z-index: 440;           /* below .float-panel (450) so the float panel
                               chevron/close are never occluded if anything
                               ever overlaps. */
    width: 272px;           /* matches .float-panel width (Home.css:486) */
    background: rgba(13, 19, 16, 0.93);          /* matches .float-panel */
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid rgba(42, 53, 48, 1);        /* matches .float-panel */
    border-radius: 12px;                          /* matches .float-panel */
    overflow: hidden;
    color: #E8F0EC;
    font-family: var(--font-mono);
  }
  .overlays-legend-summary {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    padding: 12px 16px;                            /* matches .fp-summary */
    background: none;
    border: none;
    cursor: pointer;
    text-align: left;
    min-height: 44px;                              /* matches .fp-summary */
    color: inherit;
    transition: background 0.15s ease-out;
  }
  .overlays-legend-summary:hover { background: rgba(255,255,255,0.02); }  /* matches .fp-summary */
  .overlays-legend:not(.overlays-legend--open) .overlays-legend-summary {
    border-bottom: 1px solid transparent;          /* matches .fp-summary */
  }
  .overlays-legend--open .overlays-legend-summary {
    border-bottom-color: rgba(42, 53, 48, 1);      /* matches .float-panel--open .fp-summary */
  }
  .overlays-legend-title {
    font-family: var(--font-mono);
    font-size: 13px;                               /* panel-header role, matches .fp-summary */
    font-weight: 600;
    letter-spacing: 0.06em;                        /* matches design-system panel-header */
    text-transform: uppercase;
    color: #E8F0EC;                                /* ink, not signal — this is a panel
                                                      header, the green is reserved for
                                                      active/selected state */
  }
  .overlays-legend-chevron {
    color: rgba(138, 158, 147, 1);                 /* matches .fp-chevron */
    flex-shrink: 0;
    transition: transform 0.2s ease-out;           /* matches .fp-chevron */
  }
  .overlays-legend--open .overlays-legend-chevron {
    transform: rotate(180deg);                     /* matches .fp-chevron--open */
  }
  .overlays-legend-rows {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 10px 16px 12px;
  }
  .overlays-legend-row {
    display: flex;
    align-items: center;
    gap: 8px;
    white-space: nowrap;
    /* off-state opacity for disabled/tertiary; same value as
       .nature-legend's ink-faint rows. */
    transition: opacity 0.15s ease-out;
  }
  .overlays-legend-row--off {
    opacity: 0.35;
  }
  .overlays-legend-swatch {
    width: 8px;
    height: 8px;
    border-radius: 50%;                            /* circle, matches .nature-legend-dot */
    flex-shrink: 0;
    /* background set inline per row to the layer's outline color */
  }
  .overlays-legend-label {
    font-size: 12px;                               /* label role, matches design system */
    color: rgba(232, 240, 236, 0.75);              /* matches .nature-legend body */
  }
  /* Mobile: collapse into a compact pill (matches .nature-legend--mobile
     pattern at Home.css:909-1019). The 4 swatches sit in a horizontal
     row; the chevron is hidden because the whole pill is the toggle. */
  .overlays-legend--mobile {
    bottom: 80px;                                  /* above nature-legend mobile toggle */
    width: auto;
  }
  .overlays-legend--mobile .overlays-legend-rows {
    flex-direction: row;
    gap: 8px;
    padding: 8px 14px;
  }
  .overlays-legend--mobile .overlays-legend-chevron { display: none; }
  .overlays-legend--mobile:not(.overlays-legend--open) .overlays-legend-rows {
    display: none;                                 /* hide the row strip when collapsed */
  }
  .overlays-legend--mobile:not(.overlays-legend--open) .overlays-legend-summary {
    padding: 8px 14px;
    gap: 8px;
  }
  .overlays-legend--mobile:not(.overlays-legend--open) .overlays-legend-title {
    font-size: 10px;
    letter-spacing: 0.08em;
  }
  ```

### `frontend/src/i18n.js`

- **What changes**: add one key per language.
- **PT** (insert after the `natureLegend` / `confidenceLegend` block,
  `i18n.js:82-89`):
  ```js
  overlaysLegend: 'Sobreposições',
  ```
- **EN** (insert after the `natureLegend` / `confidenceLegend` block,
  `i18n.js:277-284`):
  ```js
  overlaysLegend: 'Overlays',
  ```

### `frontend/src/components/Home.test.js` (new file)

- **What changes**: add one RTL render test covering:
  1. The card is in the DOM and has `aria-expanded` matching the state.
  2. The 4 rows render with the right swatch background colors and the
    right labels (use a stub `t` and a stub `MapaCard` wrapper).
  3. Toggling a `showX` prop dims the matching row (class
    `overlays-legend-row--off`).
  4. Clicking the chevron toggles `aria-expanded`.
  - The test file does not exist today; create `Home.test.js` adjacent to
    `Home.js` with a minimal test (jest + react-testing-library are
    already in `react-scripts` defaults).
  - This is the only automated test in the change; the rest is manual QA.

## Edge cases

- **Float panel expanded (max-height 420px)**: the overlays-legend's
  `bottom: 460px` keeps it above the float panel's expanded footprint
  (20 + 420 + 20 = 460). No overlap, no z-index conflict.
- **Float panel collapsed (~64px)**: there is a visible ~376px gap between
  the overlays-legend and the collapsed float panel. The user can collapse
  the overlays-legend for a tighter stack.
- **All 4 layers off**: card still renders (matches Q3 — always show with
  dim), so the user can see "what would these colors be if I turned them
  on". All 4 rows at 35% opacity.
- **Mobile first paint**: card is collapsed by default (`useState(!isMobile)`),
  so the mobile user sees a compact title pill, not a horizontal strip of
  labelled boxes. Tap to expand.
- **Mobile + nature-legend also expanded**: different sides (overlays =
  right, nature = left). No collision.
- **Resize from desktop to mobile after the user has opened the card**:
  the `useState` is initialized once; the user's open/closed state is
  preserved. If they had the card open, on entering mobile they see the
  expanded mobile variant. To force-collapse on entering mobile, a
  `useEffect` is needed; the plan accepts the current behavior (the
  majority case) and documents it.
- **No `showDeforest` / `showIndigenous` / `showConservation` / `showCar`
  in scope at the JSX site**: these are all defined locally in `MapaCard`
  (e.g. `Home.js:910` declares `showCar`). The legend JSX lives inside
  `MapaCard`'s return, so the local re-declared versions are the ones in
  scope. **No prop drilling required.**
- **Satélite toggle is intentionally not in the legend** (Q2): if the
  user adds it later, the JSX row list is the only place to update.
- **z-index interaction with `prodes-check` (`z-index: 490`)**:
  `prodes-check` is on the LEFT side (`left: 16px`), overlays-legend is
  on the RIGHT side (`right: 20px`). No horizontal collision. If a
  user has both panels at full size, the right and left columns are
  independent.

## Verification

- **Build**: `cd frontend && npx react-scripts build` (must compile
  without errors or warnings about missing keys / unused state).
  ✅ Passed (exit 0). Only pre-existing warnings remain (GeoBreakdown.js:44,
  Home.js:485, Home.js:1889) — none from this change. NOTE: `CI=true` would
  escalate those pre-existing warnings to errors; this is a repo-wide
  pre-existing condition, not introduced here.
- **Test**: RTL render test **DEFERRED — infeasible in this repo.** There is
  no `@testing-library/*` dependency, no `setupTests.js`, no `test` script,
  and no existing test files in `frontend/`. Adding one requires installing
  new dev deps + mocking react-leaflet's MapContainer in jsdom — scope creep
  beyond this S-sized change. The card is covered by manual QA below.
  (See "Open questions" C-6.)
- **Manual — desktop** (1280×800):
  1. Open the home map at `/`. Confirm a card titled "SOBREPOSIÇÕES"
     appears in the bottom-right, **272px wide** (same as the float
     panel below it), `bottom: 460px` (above the float panel's
     expanded footprint).
  2. Confirm 4 rows: red dot + "Desmatamento", amber dot + "Terras
     Indígenas", green dot + "Unid. Conservação", magenta dot + "CAR".
  3. Toggle each layer off via the top bar — the matching row dims
     (~35% opacity), the others stay bright.
  4. Toggle all 4 off — card still visible, all 4 rows dim.
  5. Click the chevron — card collapses to just the title bar (the
     `▾` rotates 180° to `▴`); click again — card expands (rotates
     back).
  6. Open the float panel (alerts) — the overlays-legend should NOT
     be visually overlapped (anchored at `bottom: 460px`, above the
     420px float panel expanded height).
  7. Compare visual chrome: same border-radius (12px), same background
     opacity (0.93), same border color (`rgba(42,53,48,1)`), same
     header typography (13px, 0.06em, uppercase, weight 600, ink
     color, not signal green — the green is reserved for active
     state).
- **Manual — mobile** (DevTools 375×667):
  1. On first paint, the card is a compact title pill ("SOBREPOSIÇÕES")
     at bottom-right, above the nature-legend pill.
  2. Tap the pill — 4 colored dots expand in a horizontal row, no
     labels.
  3. Tap again — collapses back to the title pill.
  4. Toggle a layer off — the matching dot stays in place at 35%
     opacity.
- **Visual diff against float panel**: side-by-side, the two cards
  should look like siblings — same width, same border, same border-
  radius, same background, same chevron style. The only difference is
  the title text and the content rows.
- **Done criteria**: the legend card is visible on `/` desktop and
  mobile, shows 4 rows in the correct colors (matching what the user
  sees on the map), dims rows whose layer is off, and collapses/expands
  on click. No console warnings. The new RTL test passes. No
  regressions in the float panel or nature-legend.
  ✅ Verified in browser (served build on :5100): desktop expanded by
  default, 4 rows correct colors (PRODES #C62828, TI #f59e0b, UC
  #4ade80, CAR #FF84FF), dim state tracks layer toggles, chevron
  collapse/expand works, positioned 16px above float panel at
  `bottom: 92px`, 272px wide. Mobile (375px): fresh load = collapsed
  pill, tap expands to 4 dots horizontal row with labels hidden, sits
  above the nature-legend toggle without overlap. RTL test deferred
  (C-6).

## Follow-up (user request, 2026-08-11) — implemented + verified

- **Overlays legend mobile = mesma esquema do natureza de fogo**: pill
  `overlays-legend-toggle` (140×40) que abre um modal centralizado
  (reusa `.nature-legend-card`/`card-inner`/`card-header`/`card-close`)
  com as 4 linhas rotuladas. Overlay `position: fixed; inset: 0; z-index
  600`, bg `rgba(10,15,13,0.65)` — idêntico ao natureza.
- **Pontos coloridos removidos** do pill mobile do natureza de fogo
  (`.nature-legend-toggle-dots` e o span removidos do JSX).
- **Ambos os pills com mesmo tamanho**: `min-height: 40px; min-width:
  140px` em `.nature-legend-toggle` e `.overlays-legend-toggle`.
- **Bug fix**: o branch desktop do overlays usava `(!isMobile ||
  showOverlaysLegend)` que é sempre true no desktop — quebrava o colapso.
  Corrigido para `showOverlaysLegend && (...)` em cada branch.
- **Verificado no browser**: mobile 400px — ambos pills 140×40, modais
  abrem com as infos; desktop — collapse/expand OK, rótulo CAR completo
  "Cadastro Ambiental Rural".

## Standards / common-mistakes referenced

- `.agents/DESIGN.md` — color tokens (signal/ink/ember), typography
  (panel-header, label), elevation (border-only — no shadows), component
  patterns (float panel, layer-toggle pills). Drives the swatch circle
  + 12px border-radius + 13px panel-header + `--ink-muted` chevron
  decisions.
- `.agents/common-mistakes/common-mistakes.md` — none directly apply to
  this UI-only change (no Redis, no DETER, no ingest, no tests with
  dates). Confirmed by review of the file.
- `.agents/AGENTS.md` — project conventions; not read in this pass
  because the change is small and the design system is the dominant
  constraint.

## Estimated scope

S — one new card, ~40 lines JSX, ~110 lines CSS, one i18n key, one new
RTL test (~30 lines), no backend changes. (Implemented: JSX ~45 lines,
CSS ~95 lines, i18n +2 keys. RTL test deferred — see C-6.)

## Implementation notes (verified during execution)

- **CSS source order matters for the mobile override.** The desktop
  `.overlays-legend` block MUST appear before the `@media (max-width:
  720px)` block in the file. Both `.overlays-legend` and
  `.overlays-legend--mobile` are single-class selectors (specificity
  0,1,0), so the later-in-source rule wins regardless of the media
  query. Initially placed after the media block, the desktop `bottom:
  92px`/`right: 20px`/`width: 272px` won over the mobile
  `bottom: 104px`/`right: 8px`/`width: auto`, causing a collision with
  the nature-legend toggle on mobile. Fixed by relocating the desktop
  block before `/* ── Responsive ── */`.
- **Mobile `bottom: 104px` verified**: clears the nature-legend toggle
  which occupies 58–98px from the bottom (`Home.css:912-916`). Measured
  legend bottom edge 563px vs toggle top 569px at 375×667.
- **Desktop `bottom: 92px` verified**: collapsed float panel is ~52px
  tall (28px count + 24px padding, border-box), giving a ~16px visual
  gap to the legend bottom edge.

## Open questions (CONSIDER from review)

- **C-1 (from review)**: defer mobile to a follow-up? — Decision: **no**;
  mobile is a ~10-line CSS variant and the reviewer's larger concern
  (M1 — first paint being a labelled horizontal strip) is fixed by the
  `useState(!isMobile)` default. Keep mobile in this pass.
- **C-2 (from review)**: `min-height: 44px` to match `.fp-summary` —
  **applied** (see CSS above).
- **C-3 (from review)**: chevron glyph + rotation match `.fp-chevron` —
  **applied** (lucide `ChevronDown` + `rotate(180deg)` open, color
  `rgba(138,158,147,1)`).
- **C-4 (from review)**: off-state opacity token — **deferred**; the
  existing `.nature-legend` uses raw `opacity: 0.35` too, and the
  comment in the CSS notes the parallel. If a token is added later it
  can be swapped in one place.
- **C-5 (from review)**: rename to `PRODES_OVERLAY_COLOR` —
  **applied**.
- **C-6 (implementation)**: RTL test deferred — the repo has no test
  infra (`@testing-library` absent, no `setupTests.js`, no `test`
  script). If a test is wanted later, first bootstrap RTL + a Leaflet
  jsdom mock in a separate increment, then add a render test for the
  legend rows.
