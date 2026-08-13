# Fix TI/UC Overlay Regression (ETag 304 crash)

## Context

The **Terras Indígenas (TI)** and **Unidades de Conservação (UC)** overlays stopped
rendering on the map. The frontend lazy-loads their GeoJSON from
`/api/indigenous-lands` and `/api/conservation-units` (see
`frontend/src/components/Home.js:1934-1968`). The browser console shows:

```
GET /api/indigenous-lands failed: net::ERR_EMPTY_RESPONSE
Indigenous lands fetch error: TypeError: Failed to fetch
```

The backend serves the full body on a cold request (200, ~226 KB), but the
**second** request — the one the browser sends with `If-None-Match: <etag>` for
revalidation — crashes and returns an empty reply. The backend error log confirms:

```
Handler error: app/server.lua:163: attempt to concatenate field '?' (a nil value)
  app/server.lua:163: in function 'send_response'
  app/server.lua:300: in function 'send'
  main.lua:136: in function 'serve_geo_lookup'
```

Intended outcome: TI/UC overlays render on both first load and subsequent
revalidations; the 304 revalidation path returns a proper `304 Not Modified`
instead of crashing.

## Root cause

`backend-lua/app/server.lua` `send_response` builds the status line with a Lua
**operator-precedence bug**:

```lua
"HTTP/1.1 " .. status .. " " .. ({ ... })[status] or "Unknown",
```

In Lua, `..` binds tighter than `or`, so this parses as:

```lua
("HTTP/1.1 " .. status .. " " .. ({ ... })[status]) or "Unknown"
```

When `status == 304`, the status map has no `[304]` entry, so `({...})[304]` is
`nil`, and the concatenation `... .. nil` raises
`attempt to concatenate field '?' (a nil value)` **before** `or "Unknown"` can
apply. The handler dies, `handle_request` catches it and logs 500, and the socket
closes with no body → `ERR_EMPTY_RESPONSE`.

The `or "Unknown"` fallback is dead code for any status missing from the map —
it can never run because the concatenation errors first.

## Assumptions and decisions

- Decision: fix the precedence bug with parentheses AND add `[304] = "Not Modified"`
  to the status map. Source: code @ `backend-lua/app/server.lua:157-163`.
  The parentheses make the `or "Unknown"` fallback actually work for any future
  status; the `[304]` entry gives the correct reason phrase. Both are needed.
- Decision: scope is the Lua backend only — no frontend change. Source: verified
  the frontend fetch/cache logic (`Home.js:1934-1968`, `toFeatureCollection`)
  is correct; the failure is purely the backend 304 crash.
- Decision: `frontend_server.lua` is **dead code** — it is referenced nowhere
  (no script, Makefile, or C file loads it; verified by repo-wide grep). The
  real frontend server is `yvy-server.c` (compiled to `yvy-server`), a pure-C
  proxy that relays the backend's response bytes verbatim. It has the same
  precedence bug but already has `[304]` in its map, so 304 works there. Fixing
  it is optional cleanup of dead code, NOT required for this regression and NOT
  on the live route path. Source: grep for `frontend_server` returns only the
  file itself; `backend-lua/Makefile` builds `yvy-server` from `yvy-server.c`.
- Assumption: the `yvy-server` C wrapper on port 5001 proxies `/api/*` to the
  Lua backend on 5000, so **the single `server.lua` fix resolves BOTH ports**
  (5000 and 5001). Source: `yvy-server.c` `proxy_to_backend` relays the backend
  response bytes verbatim (`BACKEND_PORT_DEFAULT 5000`); observed identical
  `ERR_EMPTY_RESPONSE` on both ports.

## Files to touch

### backend-lua/app/server.lua
- What changes: fix the status-line construction in `send_response` so a status
  missing from the map falls back to `"Unknown"` instead of crashing, and add
  `304` to the map.
- Function(s): `send_response(skt, status, body, content_type, extra_headers)`
  (unchanged signature).
- Data shapes: the status reason-phrase map gains `[304] = "Not Modified"`.
- Integration points: called by `ctx:send`/`ctx:json`/`ctx:error` and
  `serve_static`. The 304 path is reached from `serve_geo_lookup`
  (`main.lua:136`) and `deforestation_stats.get_historical`
  (`app/routes/deforestation_stats.lua:67`).
- Error paths: previously the 304 path raised and produced an empty reply; after
  the fix it returns a valid `304 Not Modified` with `Content-Length: 0`.

### backend-lua/app/frontend_server.lua (optional cleanup of dead code)
- What changes: apply the same parentheses fix to its `send_response` status line
  so the `or "Unknown"` fallback works for any status not in its map.
- Function(s): `send_response(skt, status, body, content_type, extra_headers)`.
- Integration points: **none** — this file is dead code, referenced nowhere in
  the repo (no script, Makefile, or C file loads it). The live frontend server
  is `yvy-server.c`. This edit is optional consistency cleanup only; it does
  not affect the TI/UC regression. If skipped, no behavior changes.

## Edge cases

- **First request (no `If-None-Match`)**: returns 200 with full body — unchanged.
- **Revalidation with matching ETag**: returns `304 Not Modified`, empty body,
  `Content-Length: 0` — the fix.
- **Revalidation with stale/mismatched ETag**: returns 200 with full body —
  unchanged (verified: wrong ETag already returns 200).
- **Any other status missing from the map** (e.g. a future 3xx): now falls back
  to `"Unknown"` instead of crashing — the precedence fix makes the fallback live.
- **Redis down**: `build_lookup_geojson` falls through to file read; the 304
  crash is independent of Redis and is fixed regardless.

## Verification

- Run: `cd backend-lua && busted --verbose tests/*.lua` (project check command
  is `make test-lua`).
- Tests to add/update: `send_response` is a `local function` in `server.lua` and
  the module only exports `_M.route`/`_M.start`, so it is not directly callable
  from a test. To make the precedence bug testable, export it as
  `_M.send_response = send_response` (test-only export; note it in a comment).
  Then add a unit test in a new `tests/test_server_response.lua` that:
  - builds a fake socket capturing bytes written to `skt:send(...)`;
  - calls `_M.send_response(fake_skt, 304, "", "application/json", {})` and
    asserts the first line is `HTTP/1.1 304 Not Modified` and no error is raised;
  - calls `_M.send_response(fake_skt, 418, "", "application/json", {})` and
    asserts the first line ends with `Unknown` (proves the `or "Unknown"`
    fallback now works for statuses missing from the map).
- Manual:
  1. `curl -s -D - -o /dev/null http://127.0.0.1:5000/api/indigenous-lands` →
     capture `ETag`.
  2. `curl -s -D - -o /dev/null -H "If-None-Match: <etag>" http://127.0.0.1:5000/api/indigenous-lands`
     → expect `HTTP/1.1 304 Not Modified`, `Content-Length: 0`, exit 0 (not 52).
  3. Repeat for `/api/conservation-units`.
  4. Browser: reload the map, toggle "Terras Indígenas" and "Unid. Conservação"
     on and off — polygons render and no `ERR_EMPTY_RESPONSE` in console.
- Done criteria: the 304 revalidation request returns a valid `304 Not Modified`
  (no crash, no empty reply), and TI/UC overlays render in the browser.

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` — general principle: a silent
  empty response on a revalidation path is a data-integrity/UX regression; the
  fix must be verified end-to-end (curl + browser), not just by unit test.

## Estimated scope

S

## Status

- [x] **Done (2026-08-13)**: fixed `send_response` precedence + added `[304]`
  in `server.lua`; exported `_M.send_response` (test-only); added
  `tests/test_server_response.lua` (3 cases); applied parens fix to dead-code
  `frontend_server.lua`. Full suite: 303 successes / 0 failures. Manual curl
  verified: TI & UC revalidation return `304 Not Modified` / `Content-Length: 0`
  (exit 0, was exit 52); wrong ETag still returns 200 with full body.

## Open questions (CONSIDER from review)

- `Content-Length: 0` on a 304 is non-standard but harmless — RFC 9110 says a
  304 must not include a body and typically omits Content-Length/Content-Type.
  The code will emit `Content-Length: 0` (from `#body` of `""`); browsers
  tolerate it, so no change needed.
- The "no frontend change" decision rests on the assumption that the browser
  actually sends `If-None-Match`. The root cause is clearly backend (confirmed
  by the error log), so this is low-risk; the browser console error
  disappearing is the end-to-end confirmation (already in manual verification).
- `frontend_server.lua` is dead code (referenced nowhere), so its fix is
  optional cleanup, not defensive consistency for a live server. The real
  frontend server is `yvy-server.c`, which relays backend bytes verbatim.
- The C wrapper relies on EOF for 304s: `parse_content_length` returns 0 for
  `Content-Length: 0`, so `have_content_length` stays 0 and the wrapper reads
  until EOF. For the 304 path no detached subprocess holds the fd, so EOF
  arrives promptly — works, but the manual verification on port 5001 is the
  right guard.
