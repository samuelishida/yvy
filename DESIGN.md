---
# Color tokens
colors:
  canvas: "#0A0F0D"          # deepest dark — map background, app shell
  surface-100: "#141A17"     # floating panels (canvas +7%)
  surface-200: "#1A211D"     # panel hover states, section dividers (canvas +9%)
  surface-300: "#1F2822"     # active layer pill, expanded panel header (canvas +12%)
  border: "#2A3530"          # hairline borders on panels, 1px
  signal: "#00C97A"          # Yvy brand green — logo, active nav, layer active state
  signal-dim: "#00855A"      # signal at 65% — secondary badges, confidence low
  ink: "#E8F0EC"             # primary text — panel headers, nav items
  ink-muted: "#8A9E93"       # secondary text — timestamps, subtitles
  ink-faint: "#4D6358"       # tertiary — disabled states, axis labels
  ember-low: "#FFAD00"       # fire density low — heatmap cool end
  ember-mid: "#FF6200"       # fire density medium
  ember-high: "#C62828"      # fire density high — heatmap hot end
  alert-ring: "#FF6200"      # pulse-ring color for high-confidence individual cluster markers

# Typography
typography:
  family-ui: "'IBM Plex Sans', 'Inter', system-ui, sans-serif"
  family-mono: "'IBM Plex Mono', 'JetBrains Mono', monospace"
  roles:
    panel-header:
      size: "13px"
      weight: 600
      line-height: 1.2
      letter-spacing: "0.06em"
      transform: uppercase
    body:
      size: "14px"
      weight: 400
      line-height: 1.5
      letter-spacing: "0"
    label:
      size: "12px"
      weight: 500
      line-height: 1.3
      letter-spacing: "0.02em"
    data-large:
      size: "28px"
      weight: 600
      line-height: 1.1
      font-variant-numeric: tabular-nums
    data-small:
      size: "13px"
      weight: 500
      line-height: 1.2
      font-variant-numeric: tabular-nums
    nav:
      size: "13px"
      weight: 500
      line-height: 1
      letter-spacing: "0.01em"

# Spacing (4pt base)
spacing:
  1: "4px"
  2: "8px"
  3: "12px"
  4: "16px"
  6: "24px"
  8: "32px"
  12: "48px"
  16: "64px"
  24: "96px"

# Radius
radius:
  sm: "4px"
  md: "8px"
  lg: "12px"
  pill: "9999px"

# Elevation (border-only strategy — no drop shadows on map surfaces)
elevation:
  panel: "inset 0 0 0 1px var(--border)"
  panel-raised: "inset 0 0 0 1px var(--surface-300)"

# Motion
motion:
  fast: "100ms ease-out"
  standard: "200ms ease-out"
  slow: "350ms ease-in-out"
  pulse-ring: "1400ms ease-out infinite"   # for high-confidence cluster rings
---

## Overview

Yvy's design system is a minimal scientific dark theme. The map is the primary surface — all chrome is subordinate to it. UI elements are dark glass panels (near-opaque, hairline-bordered) that float over the map without obscuring it. Color is functional: the brand green signals active/selected state; the ember gradient encodes fire density; everything else is ink on dark.

The `unified-shell` layout means the map is never partitioned by a permanent sidebar or bottom strip. Users see Brazil first, data second. The consolidated float panel bottom-right is the only persistent UI element below the top bar.

Both personas — Renata (returning citizen) and Carlos (first-timer) — demand legibility in under 20 seconds. Density compresses toward the float panel; the map stays open.

## Colors

`--canvas` (`#0A0F0D`) carries a green undertone — not blue-black, which reads as generic tech. This anchors the "Grounded" brand pillar visually: a Brazilian forest tool, not a Silicon Valley dashboard.

`--signal` (`#00C97A`) is the single brand color. Used only for: logo mark, active navigation state, active layer toggle. Nowhere else. If it appears somewhere that isn't "active/selected," it is wrong.

`--ember-low` → `--ember-mid` → `--ember-high` is the fire data gradient. These three values are the only colors that encode environmental data. They should never appear in UI chrome — no buttons, no borders, no backgrounds outside the map heatmap layer and the alert severity indicator.

`--ink-muted` and `--ink-faint` descend in visibility — use them strictly for secondary and tertiary information. If the user doesn't need to read it to complete their task, it gets muted.

## Typography

IBM Plex Sans is the UI family. It reads as scientific and slightly formal without being cold — appropriate for data that carries civic consequence. Tabular numerals on all data values (`font-variant-numeric: tabular-nums`) prevent column-width jitter when numbers update.

`panel-header` role uses uppercase tracking (0.06em) to separate structural labels from content. Applies to: "ALERTAS AO VIVO", "FOCOS POR BIOMA", layer section headers.

`data-large` is the hero number in the float panel — total foci count. Big, legible, tabular. Single use.

## Fire Data Encoding (key system decision)

**Replace individual dot markers with a heatmap density layer.**

The existing design places one marker per fire detection point — thousands of yellow/red dots that read as visual noise and convey no hierarchy. The redesign uses a smooth density gradient overlay:

- The map layer blends fire detection counts into a spatial heatmap (amber at low density → deep red at high density)
- Individual high-confidence clusters (INPE confidence ≥ 70%) render as a ring marker with `--alert-ring` color, 16px outer diameter, 2px stroke, animated pulse via `motion.pulse-ring`
- Low-confidence detections vanish into the heatmap — not individually addressable
- Layer toggle "Focos de Calor" controls both the heatmap and the ring markers together

This approach: reduces visual noise by ~95%, maintains spatial accuracy, communicates urgency through density gradient rather than dot quantity.

## Elevation

No drop shadows on any panel. The map is a light source — soft glows on panels break the illusion that the UI is floating above the terrain. Instead, panels use hairline borders (`--border`, 1px, `elevation.panel`) as the only depth signal. This is the same approach used by Windy.com and NASA Worldview.

## Components

**Top bar (`#canvas`, 48px, full-width)**
- Left: Yvy logo mark + wordmark at 14px medium
- Center: primary nav (Início · Notícias · Dashboard · Mapas Temáticos) — `nav` type role, active state uses `--signal` underline (2px) not background fill
- Right: layer toggle group — each layer is a pill (`radius.pill`, `surface-200` background, `ink-muted` label). Active layer: `surface-300` background, `signal` left border (2px), `ink` label
- On mobile (< 768px): layer toggles collapse into a single icon button that opens a bottom sheet

**Float panel (`surface-100`, `elevation.panel`, `radius.lg`, 280px wide)**
- Anchored bottom-right, 24px margin from edges
- Collapsed state: shows `data-large` total foci count + active biome alert (highest severity). `panel-header` label "ALERTAS AO VIVO". Expand chevron bottom-right.
- Expanded state: grows upward. Two sections separated by a 1px `border` rule:
  - Alerts section: list of high-confidence clusters with location, confidence badge, timestamp
  - Focos por Bioma section: horizontal bar chart, 6 biomes, bars in `--ember-mid`, labels in `--ink`, counts in `--data-small`
- No separate bottom strip — this panel absorbs both former UI elements

**Layer toggle pills**
- Display name in Portuguese, icon left (16px)
- States: default (`surface-200`, `ink-muted`), active (`surface-300`, 2px `signal` left border, `ink`), hover (`surface-300`, `ink`)
- Transition: `motion.fast`

**Cluster ring marker (map overlay)**
- Only rendered for INPE confidence ≥ 70%
- 16px outer diameter, 2px stroke, `--alert-ring` color
- Animated: ring expands from 16px to 28px and fades, repeating at `motion.pulse-ring`
- Click/tap opens tooltip: location name, confidence %, satellite, timestamp

## Do's and Don'ts

**Do:**
- Use `--signal` only for active/selected states
- Use tabular numerals on all live-updating data values
- Keep the float panel as the single data entry point — resist adding a second panel
- Encode fire severity through heatmap gradient density, not dot color variety
- Show layer labels in Portuguese throughout

**Don't:**
- Don't add a bottom stats strip — it was removed deliberately; the float panel holds that data
- Don't use `--ember-*` colors anywhere outside the map layer or alert severity indicator
- Don't animate map layer transitions (heatmap) — only animate UI state changes
- Don't show individual markers for low-confidence detections
- Don't use background fills on nav active state — use the `--signal` underline only
- Don't show more than 8 items in the alerts list without pagination — no infinite scroll on a floating panel
