---
name: Yvy Home (Map)
register: product
layout: unified-shell
---

## Users

**Renata — Concerned Citizen (primary)**
Brazilian adult, any device, fire season. Reads a headline, opens Yvy to check whether her region is in the orange zone. Returns periodically during fire season. Knows what the platform does; does not configure layers. Scene: phone in hand at home in Mato Grosso do Sul, wants spatial orientation in under 20 seconds.

**Carlos — First-Timer**
22, São Paulo, arrived via a social media link in a fire news thread. Never used Yvy before. Expects to understand the map without reading documentation. Scene: mobile browser, 30-second attention window, zero tolerance for unexplained UI. Needs "what am I looking at" resolved by the interface itself.

## Brand Personality

**Authoritative** — data from INPE and official sources. Every label, number, and encoding must be correct and traceable. No approximations dressed as facts.

**Grounded** — Brazilian ecology, Guaraní name, regional identity. Not generic global tech. Language, type, and visual references stay anchored in Brazil.

**Clear** — the user must understand what they are looking at within 20 seconds of arrival. Legibility over density. Hierarchy over completeness.

## Restrictions

- No casual humor, playful micro-copy, or exclamation marks
- No color used for decoration — every color encodes data state or brand identity
- No animation that does not communicate state change
- No individual dot markers at scale — replace with density heatmap; reserve point markers for high-confidence clusters only
- No biome stats in a separate bottom band — integrate into the consolidated float panel
- No more than two simultaneous floating panels on any viewport

## Layout

`unified-shell`: one 48px top bar carries logo, primary nav, and layer toggles. Single float panel anchored bottom-right: live alert tally + biome summary, expandable in-place. Map canvas unobstructed everywhere else. On mobile, layer toggles collapse to a single icon that opens a bottom sheet.
