# Restore auto-scroll in alert and biome panels

## Context

The Home page float panel contains two tabs: **alertas** (alerts) and **biomas** (biomes). Historically, hovering a fire on the map highlighted the matching alert row in the panel and the map auto-panned to the alert center. The parallel mobile-layout rework recently stubbed the panel callbacks (`onAlertEnter` / `onAlertLeave` / `onBiomeHover`) to no-ops at the `FloatPanel` call site to avoid layout churn, but this removed the feedback loop and the auto-scroll behavior that kept the active row visible. This plan restores the auto-scroll while keeping the mobile layout intact.

## Assumptions and decisions

- Decision: keep the panel **collapsed-by-default** behavior and the mobile bottom-sheet CSS as-is. Only the wiring between the map hover state and the panel content changes. Source: code @ [frontend/src/components/Home.js:571-L585](frontend/src/components/Home.js:571-L585) and [frontend/src/Home.css:470-L620](frontend/src/Home.css:470-L620).
- Decision: restore the three callbacks to the real handlers already defined in the parent component: pass `onAlertEnter={onAlertEnter}`, `onAlertLeave={onAlertLeave}`, `onBiomeHover={onBiomeHover}`. Source: code @ [frontend/src/components/Home.js:1536-L1542](frontend/src/components/Home.js:1536-L1542) currently passes `() => {}`. The real handlers are `handleAlertEnter`, `handleAlertLeave`, and `handleBiomeHover` at [frontend/src/components/Home.js:1672-L1702](frontend/src/components/Home.js:1672-L1702), which include a 400 ms fly-to debounce and boundary-fetch-on-first-hover logic; `MapaCard` already receives them as props.
- Decision: keep the active state transient (hover-driven) rather than sticky/click-driven, matching the original bidirectional feedback commit. Source: commit `04d90839` and current state wiring in the Home component around `alertHoverId`, `fireAlertId`, `activeBiome`.
- Assumption: the active row must scroll into view inside the **fp-content** scrollable area, not the whole page. The CSS already uses `overflow-y: auto` on `.fp-content` ([frontend/src/Home.css:578-L580](frontend/src/Home.css:578-L580)).
- Decision: use `scrollIntoView({ block: 'nearest', behavior: 'smooth' })` on the DOM node of the active alert row / biome row. `block: 'nearest'` avoids jumping the whole list around when the row is already visible.
- Assumption: the fix should also restore the existing map pan-to-alert behavior. `flyToAlert` is derived from `flyToAlertId` at [frontend/src/components/Home.js:1019-L1021](frontend/src/components/Home.js:1019-L1021), and `handleAlertEnter` already updates `flyToAlertId` after a 400 ms debounce at [frontend/src/components/Home.js:1676](frontend/src/components/Home.js:1676). So passing the real handlers restores both panel scroll and map panning.
- Decision: do not auto-expand the panel on hover; auto-expanding the bottom sheet on mobile would cover the map. Instead, scroll only works when the panel is already open and the user is on the relevant tab. If the panel is closed, only the map ring/pan feedback is shown.

## Files to touch

### frontend/src/components/Home.js

- What changes: wire `FloatPanel` callbacks back to the real hover state setters; add refs and a `useEffect` inside `FloatPanel` to keep the active alert row or active biome row scrolled into view; add refs on the mapped row divs.

- Function(s) / signatures:
  - Modify `FloatPanel` signature stays the same, but add internal refs:
    - `const activeAlertRowRef = useRef(null);`
    - `const activeBiomeRowRef = useRef(null);`
  - Add `useEffect` to scroll on active change **and** whenever the panel/tab becomes visible:
    ```js
    useEffect(() => {
      if (!open) return;
      if (tab === 'alerts' && activeAlertRowRef.current) {
        activeAlertRowRef.current.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      }
      if (tab === 'biomes' && activeBiomeRowRef.current) {
        activeBiomeRowRef.current.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      }
    }, [activeAlertId, activeBiome, tab, open]);
    ```
    Because `open` and `tab` are in the dependency array, the effect fires when the user opens the panel or switches tabs, so an already-active item is scrolled into view.
  - In the `.map((a, i) => ...)` of alerts, set ref conditionally:
    ```js
    ref={activeAlertId === a.id ? activeAlertRowRef : null}
    ```
  - Modify `BiomePanel` to accept `activeBiome`, `tab`, and `open` props, add `activeBiomeRowRef`, and run the same scroll effect inside `BiomePanel` (or have `FloatPanel` pass `activeBiomeRowRef` down and use it there). Keep `BiomePanel` memoized but now include the new props in the comparison; the active state changes are the intended re-render trigger.
    ```js
    const BiomePanel = React.memo(function BiomePanel({ onBiomeHover, activeBiome, tab, open }) {
      const activeRowRef = useRef(null);
      useEffect(() => {
        if (open && tab === 'biomes' && activeRowRef.current) {
          activeRowRef.current.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
        }
      }, [activeBiome, tab, open]);
      // ... existing fetch/sort/map, but attach:
      // ref={activeBiome === b.name ? activeRowRef : null}
    });
    ```
  - Change the `FloatPanel` call site at the bottom of `MapaCard`:
    ```js
    <FloatPanel
      alerts={alertRows}
      loaded={alerts !== null}
      activeAlertId={activeAlertId}
      onAlertEnter={onAlertEnter}
      onAlertLeave={onAlertLeave}
      airQuality={airQuality}
      temperature={temperature}
      onBiomeHover={onBiomeHover}
      activeBiome={activeBiome}
      isMobile={isMobile}
    />
    ```
    The current no-op callbacks are at [frontend/src/components/Home.js:1536-L1542](frontend/src/components/Home.js:1536-L1542).

- Data shapes:
  - `alerts` array elements already contain `a.id`, `a.tick`, `a.type`, `a.meta`, `a.state`, `a.ts`.
  - `activeAlertId` is a string/number or null.
  - `activeBiome` is a string (biome name) or null.

- Integration points:
  - `Home` owns `activeAlertId` derived from `alertHoverId || fireAlertId`, and `activeBiome` via hover state.
  - `MapController` receives `flyToAlert` (derived from `activeAlertId`) and already pans the map.
  - `BiomeHighlightLayer` receives `activeBiome` and already highlights/fits bounds.
  - The change only reconnects the panel feedback.

- Error paths:
  - If refs are `null` (row not rendered yet), the effect does nothing.
  - If `scrollIntoView` is unsupported (very old browsers), guard with `typeof ref.scrollIntoView === 'function'`.
  - No new API calls; failure modes are limited to no-scroll fallback.

### frontend/src/Home.css

- What changes: add a dedicated active class for biome rows and a small scroll margin so the scrolled row does not stick to the container edge.
- Verify `.fp-content` keeps `overflow-y: auto` and that `.float-panel--mobile.float-panel--open .fp-content` keeps a bounded `max-height` so the scroll area exists on mobile.
- Add:
  ```css
  .biome-row--active { background: rgba(255, 255, 255, 0.04); border-left: 2px solid #00C97A; }
  .alert-row--active,
  .biome-row--active { scroll-margin: 8px 0; }
  ```

## Edge cases

- **Panel closed**: no scroll occurs (the DOM nodes are unmounted). The map still highlights/pans via `MapController` and `BiomeHighlightLayer`.
- **Tab not active** (e.g. user is on *Clima*): the effect only fires for the current tab. Switching to *Alertas* or *Biomas* should immediately scroll the active row into view; include `tab` and `open` in the effect deps.
- **No active item**: refs remain null, no-op.
- **List shorter than viewport**: `scrollIntoView({ block: 'nearest' })` does nothing harmful.
- **Mobile bottom sheet**: the scroll happens inside `.fp-content`, whose `max-height` is set to `calc(55vh - 44px)` ([frontend/src/Home.css:993](frontend/src/Home.css:993)). The effect works the same as on desktop because the container is scrollable.
- **Rapid hover changes**: `behavior: 'smooth'` may queue multiple smooth scrolls. Acceptable; consider `behavior: 'auto'` on mobile to avoid motion, but keep smooth on desktop for polish. If preferred, use `behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth'`.
- **Biome hover outside panel**: if the user hovers a biome on the map/biome layer and the panel is on the biome tab, scroll to that biome row.
- **Active alert outside top-12 slice**: `sortedAlerts.slice(0, 12)` ([frontend/src/components/Home.js:612](frontend/src/components/Home.js:612)) means the active alert may not be rendered. Mitigation: expand the rendered window to include the active alert, e.g. `sortedAlerts.slice(0, Math.max(12, sortedAlerts.findIndex(a => a.id === activeAlertId) + 1))`, or remove the cap when an active alert is present. Choose the minimal change that keeps the active item in the DOM so the ref exists.
- **Touch/hover on mobile**: `onMouseEnter`/`onMouseLeave` are pointer events; taps should not auto-expand the panel. The "no auto-expand" decision avoids this.

## Verification

- Run:
  - `cd frontend && npm run build` (or the equivalent `make build-frontend` from [AGENTS.md] if available).
  - `cd /media/smk/Shared/Code/Yvy && bash scripts/dev/run-lua.sh` and `./backend-lua/yvy-server --port 5001 --backend 127.0.0.1 --static frontend/build --api-key testkey` (per current local workflow in terminal context).
  - `curl -s http://localhost:5000/api/health` and `curl -s http://localhost:5001/` should return 200.
- Manual:
  1. Open `http://localhost:5001/` on desktop.
  2. Open the float panel, choose the *Alertas* tab.
  3. Hover a fire circle on the map that belongs to an alert (or trigger `fireAlertId`).
  4. Expected: the matching alert row gets `.alert-row--active`, the panel content smoothly scrolls to that row, and the map pans to the alert center.
  5. Repeat for the *Biomas* tab: hover over a biome region or use the existing biome hover path.
  6. Expected: the matching biome row scrolls into view and the biome boundary is highlighted/fitted on the map.
  7. On mobile viewport (≤720px): open the bottom sheet, select *Alertas*, hover a fire. Expected: the row scrolls inside the sheet without expanding/collapsing the sheet.
- Tests to add/update:
  - Add a focused regression test that verifies the wiring is no longer stubbed and that `scrollIntoView` is called. Recommended location: create `frontend/src/components/Home.test.js` if Jest is configured, otherwise extend the existing Playwright script `frontend/mobile-click-test.js` with a desktop-or-mobile scenario that:
    1. Opens the float panel and the *Alertas* tab.
    2. Programmatically dispatches `mouseenter` on an alert row or simulates map fire hover (or directly calls the exposed handler if testable).
    3. Asserts that `.alert-row--active` exists and the `.fp-content` `scrollTop` is greater than 0 when the active item is below the fold.
  - Also assert that `FloatPanel` is called with non-no-op handlers after the fix; this can be a trivial search/replace guard in the test plan if no automated test file is added.
- Done criteria:
  - Hovering a map fire smoothly scrolls the corresponding alert row into view inside the panel when the *Alertas* tab is open.
  - Hovering a biome smoothly scrolls the corresponding biome row into view inside the panel when the *Biomas* tab is open.
  - Mobile bottom sheet does not auto-open or collapse unexpectedly.

## Standards / common-mistakes referenced

- No specific `.agents/standards/` or `.agents/common-mistakes/` files exist in this workspace (not listed in workspace structure). The plan follows existing project conventions from `frontend/src/components/Home.js` and `frontend/src/Home.css`.

## Estimated scope

S

## Open questions (CONSIDER from review)

- Should we remove the 12-item cap in the alerts list so every active alert is guaranteed to be rendered? The current plan mitigates by expanding the slice, but removing the cap is simpler if the list is small enough.
- Should `scrollIntoView` use `behavior: 'auto'` on mobile to avoid stacked smooth-scroll animations when hovering multiple rows rapidly?

## Implementation status

- 2026-08-08: Implemented. Files modified: `frontend/src/components/Home.js`, `frontend/src/Home.css`.
- Build verified with `npm run build` in `frontend/`: exit 0, no new warnings.
