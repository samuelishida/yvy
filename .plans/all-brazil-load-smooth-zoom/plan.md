# All-Brazil Load + Smooth Map Zoom

## Context

Yvy serves the full Brazil fire dataset on initial map load (no viewport bbox). The
`/api/fires` endpoint returns up to `MAX_RESULTS = 10000` records (entire Brazil),
a raw JSON payload of **1,277,668 bytes**. The user explicitly wants **all of Brazil
to load** on the home map — viewport-limited bbox queries are *out of scope* by
decision. The intended outcome is:

1. **Confirm that a full-Brazil payload is acceptable over the wire** — i.e., that
   gzip compression is functioning so 1.28MB raw travels as ~176KB, and guard that
   behavior so it isn't silently regressed.
2. **Restore Google-Maps-style smooth wheel zoom**, which is currently broken because
   the app loads a dead CDN script (`leaflet.smoothwheelzoom@0.1.2`) that returns 404.

Verified prod facts (vias SSH/curl, 2026-08-05):
- nginx `gzip on` with `gzip_types` including `application/json` and
  `application/javascript` — **gzip is already working** for `/api/fires`
  (1,277,668 → 175,546 bytes) and for the JS bundle (180,420 → 69,460 bytes).
- The CDN script `https://cdn.jsdelivr.net/npm/leaflet.smoothwheelzoom@0.1.2/...`
  returns **404**. The npm package `leaflet.smoothwheelzoom` **does not exist**
  (`registry.npmjs.org` → `"Error: Not found"`). The browser reports
  `net::ERR_BLOCKED_BY_ORB` for the opaque 404 and the map has no smooth zoom.
- Working upstream: `alexatiks/Leaflet.SmoothWheelZoom` (MIT, ~4.4KB, UMD/CommonJS).
  Its `Leaflet.SmoothWheelZoom.js` exports via `module.exports = factory(require('leaflet'))`,
  so it can be `require`d/imported inside the CRA bundle with no CDN.

## Architectural decisions

- **Decision: Keep the full-Brazil `/api/fires` payload; do NOT add client bbox.**
  Rationale: user requirement ("I want all Brazil to load"). The 176KB gzipped
  transfer is acceptable on the 1GB-VM + Redis-cached architecture. Alternatives
  rejected: viewport bbox (violates the stated requirement), server-side clustering
  (larger scope, out of this plan).
- **Decision: Vendor the smooth-wheel-zoom plugin as a local file imported through
  CRA's bundler, and delete the CDN `<script>` tag.** Rationale: the CDN URL is dead
  (404) and the package is not on npm, so a local vendored copy is the only
  dependency-free, no-CDN, build-integrated option. The plugin is CommonJS-compatible,
  so `import './vendor/Leaflet.SmoothWheelZoom'` in `Home.js` registers
  `L.SmoothWheelZoom` exactly as the dead script did. Alternatives rejected: rely on a
  different CDN (same fragility), drop the feature (user wants it), npm-install
  (package doesn't exist).
- **Decision: Gzip is handled as a verify-and-guard increment only.** Rationale: it is
  already on and correct. We will not change nginx gzip, only (a) document the
  intentional all-Brazil decision and (b) avoid regressions. Deploy config source of
  truth is `ansible/templates/yvy-nginx.conf.j2`; live `/etc/nginx/sites-enabled/yvy`
  matches it.

## Assumptions and answers from code

- The dead `<script>` tag lives in `frontend/public/index.html:19` (CRA injects it
  verbatim into the built `index.html`). Source: code @ frontend/public/index.html.
- `Home.js` already guards usage: `if (L && L.SmoothWheelZoom) { map.options.scrollWheelZoom='center'; map.addHandler('smoothWheelZoom', L.SmoothWheelZoom); }`.
  So vendoring a file that sets `L.SmoothWheelZoom` is sufficient — no logic change.
  Source: code @ frontend/src/components/Home.js:341-345.
- Prod auth trusts localhost; API key is irrelevant to this plan. Source: verified
  session notes.
- nginx gzip config is already correct. Source: verified live `/etc/nginx/sites-enabled/yvy`
  and `ansible/templates/yvy-nginx.conf.j2`.

## Risks accepted

- **All-Brazil 10K-record payload on cold cache (~905ms backend, 176KB transfer).**
  Accept; mitigated by Redis cache (hits ~9-10ms) and gzip. Revisit if fire season
  grows the dataset or mobile bounce becomes an issue.
- **Vendored third-party code is now in-repo.** Accept; the plugin is 4.4KB, MIT, and
  imported from a **pinned commit SHA** (recorded in the header comment), not the moving
  `master` branch.
- **Build integration of a non-ESM CommonJS file.** Low risk with CRA/webpack; verified
  the file uses the UMD `module.exports` branch. If tree-shaking complains, import it
  as a side-effect (`import './vendor/...'`) rather than a named export. If CRA ESLint
  rejects the vendored file, add an ignore entry rather than editing the vendored source.

## Increment DAG

- Inc 1 — Verify + guard gzip for all-Brazil load (S) — depends on: none — unblocks: none
- Inc 2 — Vendor smooth wheel zoom locally (S) — depends on: none — unblocks: none

Both increments are independent and could run in parallel or sequentially.

## Increments

### Inc 1 — Verify + guard gzip for all-Brazil load (S) ✅ done
**Depends on:** none
**Unblocks:** none
**Done criteria:** A docker/CI-free `curl` check documents that `GET /api/fires` with
`Accept-Encoding: gzip` returns `application/json` gzip-encoded (~176KB), and repo docs
state that the full-Brazil payload is intentional.

#### Files to touch

##### README.en.md (and/or RUNBOOK.md)
- What changes: add a short note under an existing "API"/"Performance" heading that the
  home map intentionally loads the full-Brazil `/api/fires` (up to 10K records, ~1.28MB
  raw / ~176KB gzipped) and that Redis + nginx gzip keep cold load acceptable.
- Integration points: none (documentation).
- Error paths: n/a.

##### ansible/templates/yvy-nginx.conf.j2 (comment only — no behavior change)
- What changes: confirm `gzip_types` already lists `application/json` and
  `application/javascript`; if a future reviewer removes them, the doc note references
  this file as the source of truth. No config value changes in this increment.
- Error paths: n/a.

##### scripts/verify-gzip.sh (new — the actual "guard")
- What changes: a small shell script that:
  1. Asserts the nginx template still lists both mime types:
     `grep -E 'application/json' ansible/templates/yvy-nginx.conf.j2` (and
     `application/javascript`).
  2. If a target URL is provided, curls it with `Accept-Encoding: gzip` and asserts the
     response `Content-Encoding: gzip` header (the durable signal — not exact byte
     counts, which drift as data grows).
- Function(s): none (script). Exit non-zero on any failed assertion.
- Integration points: run manually; wire into `.github/workflows/ci.yml` as a step so a
  future gzip regression fails CI instead of silently degrading.
- Error paths: curl failure → exit 1 with message; template missing a mime type → exit 1.

#### Edge cases
- n/a — this increment is verification + documentation + a CI assertion; no runtime
  behavior changes. The script must not require prod credentials; when run in CI with no
  URL, it runs only the template-grep guard.

#### Verification
- Run locally:
  ```bash
  bash scripts/verify-gzip.sh                     # template guard (no network)
  bash scripts/verify-gzip.sh https://yvy.app.br/api/fires
  ```
  Expect exit 0 and a printed `Content-Encoding: gzip` confirmation. (Curl of the URL
  requires the backend to be up — currently stopped; start the local stack or bring prod
  up first.)
- CI: `.github/workflows/ci.yml` adds `bash scripts/verify-gzip.sh` (no-URL mode).
- Tests to add/update: the script itself is the guard.
- Done: doc note merged; `scripts/verify-gzip.sh` added and wired into CI; gzip verified.

---

### Inc 2 — Vendor smooth wheel zoom locally (S) ✅ done
**Depends on:** none
**Unblocks:** none
**Done criteria:** The CDN `<script>` tag is gone; `L.SmoothWheelZoom` is available to
`Home.js` from a local file; a local `npm run build` succeeds; smooth wheel zoom works
on the built map.

#### Files to touch

##### frontend/src/vendor/Leaflet.SmoothWheelZoom.js (new)
- What changes: vendor the MIT file from
  `https://raw.githubusercontent.com/alexatiks/Leaflet.SmoothWheelZoom/master/Leaflet.SmoothWheelZoom.js`
  (4,406 bytes). Include the upstream license/attribution header in a leading comment,
  **including the exact commit SHA the file was vendored from** (fetch it via
  `git ls-remote https://github.com/alexatiks/Leaflet.SmoothWheelZoom.git refs/heads/master`)
  and the byte count — do NOT reference the moving `master` branch without pinning. Record
  the SHA so future drift is detectable.
- Function(s): registers Leaflet handler `L.Map.SmoothWheelZoom` and sets
  `L.Map.mergeOptions({ smoothWheelZoom: true, smoothSensitivity: 1 })`.
- Data shapes: n/a (side-effect module).
- Integration points: side-effect of importing `leaflet` inside the factory; invoked by
  `Home.js`'s existing `map.addHandler('smoothWheelZoom', L.SmoothWheelZoom)`.
- Error paths: if `window.L` is undefined in the browser-global branch it throws; in CRA
  the CommonJS branch executes with the bundled `leaflet`, so this never triggers.
  Webpack resolves `require('leaflet')` to the same package instance that `Home.js`
  imports, so `L.Map.SmoothWheelZoom` is registered before any render/effect runs.

##### frontend/src/components/Home.js
- What changes: add `import '../vendor/Leaflet.SmoothWheelZoom';` as a side-effect import
  near the existing `import L from 'leaflet';`. No other change; the existing
  `if (L && L.SmoothWheelZoom) { ... }` guard already does the wiring.
- Error paths: n/a.

##### frontend/public/index.html
- What changes: remove the dead `<script src="https://cdn.jsdelivr.net/npm/leaflet.smoothwheelzoom@0.1.2/dist/leaflet.smoothwheelzoom.min.js"></script>` line. This eliminates the blocking 404 request and the `ERR_BLOCKED_BY_ORB` console error.
- Integration points: CRA copies `public/index.html` to the built `index.html`.
- Error paths: n/a.

#### Edge cases
- React StrictMode double-mounts effects in dev; `Home.js` guards `L.SmoothWheelZoom`
  inside an effect with an empty dep array and calls `map.addHandler` once — no change.
- CSP: vendoring removes the need for the CDN domain in CSP (there is currently no CSP
  header in prod nginx; adding one is out of scope but this change makes it feasible
  later by removing the external script).
- CRA ESLint/noise from the vendored CommonJS file: if `npm start`/`npm run build`
  hard-fails on lint for the vendored file, add it to the ESLint ignore (e.g. an
  `.eslintignore` entry) rather than reformatting/editing the vendored source.

#### Verification
- Run:
  ```bash
  cd frontend && npm run build        # must succeed
  npm start                           # dev: confirm smooth wheel zoom works
  ```
  Then confirm the dead CDN URL is gone from built HTML:
  ```bash
  grep -c "leaflet.smoothwheelzoom" frontend/build/index.html || echo "removed"
  ```
  And confirm the handler actually bundled into the production JS output (not just dev):
  ```bash
  grep -rl "SmoothWheelZoom" frontend/build/static/js/ | head  # preserved public property
  ```
  `SmoothWheelZoom` survives Terser minification because it is assigned as the public
  property `L.Map.SmoothWheelZoom`; if it appears in a lazy chunk, account for that.
- Tests to add/update: none (build-time + manual verification).
- Done: build passes, dev map zooms smoothly, no `.smoothwheelzoom` reference in built
  HTML, and `SmoothWheelZoom` present in the built JS bundle.

---

## Cross-cutting verification

After Inc 2, run the local stack (`make run`), load `http://localhost:5001`, and confirm:
1. Home map renders the full-Brazil fire layer.
2. Mouse wheel zoom animates smoothly (was instant/jerky or broken before).
3. Browser devtools show no failed request for `leaflet.smoothwheelzoom`.
For Inc 1 gzip, run the two `curl` size checks against prod (backend restarted) or local.

## Standards / common-mistakes referenced
- AGENTS.md — build/test/deploy conventions (Lua 5.1, `make run`, CRA frontend).
- (No `.agents/standards/` present in repo besides AGENTS.md; follow its structure.)

## Open questions (CONSIDER from review)
- Should `scripts/verify-gzip.sh` also diff the live prod `/etc/nginx/sites-enabled/yvy`
  against `ansible/templates/yvy-nginx.conf.j2` before trusting a prod curl result?
  (The terminal history shows ad-hoc nginx `test.conf` experiments — prod config may
  drift from the template.)
- Confirm the vendored `alexatiks` plugin's `L.Handler.extend`/`addHandler` usage matches
  the project's installed Leaflet major version before merge (likely compatible — the old
  CDN targeted the same plugin — but a one-line check de-risks a silent no-op).
- Decide whether the CRA ESLint exception for the vendored file is needed before running
  `npm run build` (only if the build fails on lint for `src/vendor/*.js`).
- **RESOLVED:** plain `npm run build` (as `start-lua-stack.sh` runs it, without
  `DISABLE_ESLINT_PLUGIN`) fails on the vendored UMD's AMD `define` branch
  (`no-undef` at `src/vendor/Leaflet.SmoothWheelZoom.js:19,21`). Fixed by adding
  `frontend/.eslintignore` with `src/vendor/Leaflet.SmoothWheelZoom.js`. Build now
  passes and stack starts cleanly.

## Out of scope
- Client viewport bbox / pagination for `/api/fires` (user wants all Brazil).
- Server-side fire clustering.
- nginx `proxy_cache` and `/static/` immutable caching (larger, separate).
- Adding a Content-Security-Policy header in prod.
- Live deployment to the OCI VM (backend/frontend currently stopped).
