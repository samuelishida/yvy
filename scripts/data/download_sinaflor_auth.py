#!/usr/bin/env python3
"""Download Sinaflor authorized-burn data (ASV + AUTESP) → sinaflor_auth.db.

First real source for Yvy's "permitido" fire nature (.plans/sinaflor-fogo-
permitido). The sinaflor.ibama.gov.br panel requires SSO login (not scriptable);
the public open-data portal `dadosabertos.ibama.gov.br` (CKAN) carries the full
Sinaflor catalog. ASV (Autorização de Supressão de Vegetação) and AUTESP
(Autorização Especial) are used as the proxy for "queima controlada" (no such
dataset exists — `package_search?q=queima` → 0).

Flow: discover packages via CKAN at runtime (never hardcode ids) → download each
CSV resource (ZIP-aware) → normalize dates/coordinates → resolve CAR code
(offline, never in the Lua loop) → write a dedicated SQLite DB atomically.

Live schema notes (verified 2026-08-08 against the real downloads — see
.agents/common-mistakes/common-mistakes.md #4):
- Both files use `;` as separator and are UTF-8 (ASV has a BOM).
- AUTESP dates are ISO `YYYY-MM-DD`; ASV dates are `DD/MM/YYYY`. The parser
  also accepts `DD/MM/AA` (pivot 00-69→20xx, 70-99→19xx) for older exports.
- Coordinates: AUTESP uses dot decimals, ASV uses comma decimals.
- `NRO_CAR_IMOVEL_RURAL` exists ONLY in ASV (43-char SICAR code). AUTESP has no
  CAR column → the spatial fallback (lat/lon → CAR polygon) is its PRIMARY path.
- `SITUACAO` domain includes cancel/suspend values (`Autorização Cancelada`,
  `Autorização Suspensa`) — those are filtered out; `Vencida` is kept (the
  2-year window on `DATA_DE_VALIDADE` already bounds it).

The 2-year window filter (`DATA_DE_VALIDADE >= today - window`) lives here in
Python and is deterministic via `--today` (used by tests).

The DB file itself is the success marker: it is written to `<out>.tmp` and
atomically `os.replace`d only after a fully successful import, so a failed run
leaves the previous DB (and its mtime) intact. `sync-sinaflor.sh` re-runs this
when the DB mtime is older than 7 days.

Usage:
    python3 scripts/data/download_sinaflor_auth.py                # default: 2 anos (730d), todos UFs
    python3 scripts/data/download_sinaflor_auth.py --window 365   # 1 ano (uso explícito)
    python3 scripts/data/download_sinaflor_auth.py --today 2026-08-08  # override do relógio (testes)
    python3 scripts/data/download_sinaflor_auth.py --force        # re-download mesmo com DB recente
    python3 scripts/data/download_sinaflor_auth.py --ufs MT PA    # filtro por UF
    python3 scripts/data/download_sinaflor_auth.py --no-car-resolve
    python3 scripts/data/download_sinaflor_auth.py --out backend-lua/data/sinaflor/sinaflor_auth.db
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import time
import zipfile
from datetime import date, timedelta
from pathlib import Path

import pandas as pd
import requests
from shapely.geometry import Point, shape

CKAN_API = "https://dadosabertos.ibama.gov.br/api/3/action"
UA = "Mozilla/5.0 (X11; Linux x86_64) Yvy/1.0"
BATCH = 1000

# SITUACAO values that mean the authorization is NOT valid (revoked/suspended).
# `Autorização Vencida` is intentionally kept: it was valid during its window,
# and the 2-year `DATA_DE_VALIDADE` filter bounds how far back we look.
DROP_SITUACAO = {"Autorização Cancelada", "Autorização Suspensa"}

# Runtime classification of the two expected packages by title keyword. Fails
# loudly if either disappears from CKAN (never hardcode package ids).
EXPECTED_MODOS = (("ASV", "supress"), ("AUTESP", "especial"))


def _norm_col(s):
    return re.sub(r"[^a-z0-9]", "", str(s).lower())


def _find_column(df, aliases):
    """First existing column among aliases, case/punctuation-insensitive."""
    norm = {_norm_col(c): c for c in df.columns}
    for a in aliases:
        key = _norm_col(a)
        if key in norm:
            return norm[key]
    return None


def _ckan_get_json(url, params):
    for attempt in range(3):
        try:
            r = requests.get(url, params=params, timeout=60, headers={"User-Agent": UA})
            r.raise_for_status()
            data = r.json()
            if not data.get("success"):
                raise ValueError("CKAN error: {}".format(data.get("error")))
            return data
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def ckan_package_list():
    """Discover the ASV + AUTESP packages at runtime; fail if either is missing."""
    data = _ckan_get_json(CKAN_API + "/package_search", {"q": "sinaflor", "rows": 100})
    found = {}
    for p in data["result"]["results"]:
        title = (p.get("title") or "").lower()
        for modo, keyword in EXPECTED_MODOS:
            if keyword in title:
                found[modo] = {"id": p["id"], "name": p.get("name"),
                               "title": p.get("title"), "modo": modo}
                break
    missing = [m for m, _ in EXPECTED_MODOS if m not in found]
    if missing:
        raise RuntimeError(
            "CKAN sinaflor search missing expected package(s): {} (refusing to "
            "write an incomplete DB)".format(", ".join(missing))
        )
    return [found["ASV"], found["AUTESP"]]


def ckan_resource_url(package_id):
    """First non-metadata CSV resource of a package (ASV/AUTESP data file)."""
    data = _ckan_get_json(CKAN_API + "/package_show", {"id": package_id})
    res = data["result"].get("resources") or []
    csvs = [
        r for r in res
        if (r.get("format") or "").upper() == "CSV"
        and "metadados" not in (r.get("name") or "").lower()
    ]
    if not csvs:
        raise RuntimeError(
            "package {}: no CSV resource found — upstream schema changed (see "
            "common-mistake #4)".format(package_id)
        )
    return csvs[0]["url"]


def download_csv(url, dest):
    """Stream a resource to `dest`, retrying with backoff. ZIP-aware.

    Both the ASV (`.csv` URL, content-type application/octet-stream) and AUTESP
    (`.zip` URL) resources must be handled: detect ZIP by magic bytes
    (`PK\\x03\\x04`), never by extension/content-type alone, and extract the
    inner CSV member.
    """
    dest = Path(dest)
    part = dest.with_name(dest.name + ".part")
    for attempt in range(3):
        try:
            with requests.get(url, stream=True, timeout=180,
                              headers={"User-Agent": UA}) as r:
                r.raise_for_status()
                with open(part, "wb") as f:
                    for chunk in r.iter_content(chunk_size=1 << 20):
                        if chunk:
                            f.write(chunk)
            break
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)

    with open(part, "rb") as f:
        magic = f.read(4)
    if magic[:2] == b"PK":
        with zipfile.ZipFile(part) as z:
            csv_names = [n for n in z.namelist() if n.lower().endswith(".csv")]
            if not csv_names:
                raise RuntimeError("{}: zip contains no CSV member".format(url))
            with open(dest, "wb") as f:
                f.write(z.read(csv_names[0]))
        part.unlink(missing_ok=True)
    else:
        os.replace(part, dest)
    return dest


def detect_sep(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        header = f.readline()
    return ";" if header.count(";") >= header.count(",") else ","


def _parse_date(value):
    """ISO `YYYY-MM-DD`, `DD/MM/YYYY`, or `DD/MM/AA` → `YYYY-MM-DD` or None."""
    if value is None:
        return None
    v = str(value).strip()
    if not v:
        return None
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", v)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if 1 <= mo <= 12 and 1 <= d <= 31:
            return "{:04d}-{:02d}-{:02d}".format(y, mo, d)
    m = re.fullmatch(r"(\d{2})[/-](\d{2})[/-](\d{2,4})", v)
    if m:
        d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if len(str(y)) == 2:
            y = 2000 + y if y <= 69 else 1900 + y
        if 1 <= mo <= 12 and 1 <= d <= 31:
            return "{:04d}-{:02d}-{:02d}".format(y, mo, d)
    return None


def _parse_float(value):
    """Parse a decimal with dot or comma separator; None on garbage ('36.5.5')."""
    if value is None:
        return None
    v = str(value).strip().replace(" ", "")
    if not v:
        return None
    if "," in v and "." not in v:
        v = v.replace(",", ".")
    try:
        return float(v)
    except ValueError:
        return None


def normalize(df, modo, today, window_days, ufs):
    """Map a raw dataset CSV to canonical columns and apply the window filter.

    Returns (out, dropped) where `dropped` is a dict of drop-reason counts.
    """
    col = lambda aliases: _find_column(df, aliases)  # noqa: E731
    nro_col = col(["NRO_AUTORIZACAO", "NRO_REGISTRO"])
    inicio_col = col(["DATA_DE_EMISSAO"])
    fim_col = col(["DATA_DE_VALIDADE"])
    uf_col = col(["UF", "SIGLA_UF"])
    mun_col = col(["MUNICIPIO"])
    situ_col = col(["SITUACAO"])
    lat_col = col(["LATITUDE", "LATITUDE_PONTO_CENTR_EMPREEND"])
    lon_col = col(["LONGITUDE", "LONGITUDE_PONTO_CENTR_EMPREEND"])
    car_col = col(["NRO_CAR_IMOVEL_RURAL", "COD_IMOVEL"])

    out = pd.DataFrame()
    out["nro_autorizacao"] = df[nro_col].astype(str).str.strip() if nro_col else ""
    out["modo"] = modo
    out["data_inicio"] = df[inicio_col].map(_parse_date) if inicio_col else None
    out["data_fim"] = df[fim_col].map(_parse_date) if fim_col else None
    out["uf"] = df[uf_col].astype(str).str.strip().str.upper() if uf_col else ""
    out["municipio"] = df[mun_col].astype(str).str.strip() if mun_col else ""
    out["situacao"] = df[situ_col].astype(str).str.strip() if situ_col else ""
    out["lat"] = df[lat_col].map(_parse_float) if lat_col else None
    out["lon"] = df[lon_col].map(_parse_float) if lon_col else None
    out["nro_car"] = df[car_col].astype(str).str.strip().str.upper() if car_col else ""

    dropped = {}

    before = len(out)
    out = out[~out["situacao"].isin(DROP_SITUACAO)]
    dropped["cancelada_suspensa"] = before - len(out)

    before = len(out)
    out = out[out["data_inicio"].notna()]
    dropped["sem_emissao"] = before - len(out)

    out["data_fim"] = out["data_fim"].fillna("9999-12-31")

    before = len(out)
    out = out[out["data_fim"] >= out["data_inicio"]]
    dropped["janela_invalida"] = before - len(out)

    cutoff = (today - timedelta(days=window_days)).isoformat()
    before = len(out)
    out = out[out["data_fim"] >= cutoff]
    dropped["fora_da_janela"] = before - len(out)

    if ufs:
        uf_set = {u.strip().upper() for u in ufs if u.strip()}
        before = len(out)
        out = out[out["uf"].isin(uf_set)]
        dropped["uf_filtrada"] = before - len(out)

    return out.reset_index(drop=True), dropped


def classify_point(car_conn, lon, lat):
    """CAR cod_imovel of the largest-area property containing (lon, lat), or None.

    Mirrors backend-lua `car_lookup.classify_point`: RTree bbox candidates →
    decode only those → shapely point-in-polygon → match of LARGEST AREA.
    """
    rows = car_conn.execute(
        "SELECT id FROM car_rtree WHERE minLon<=? AND maxLon>=? AND minLat<=? AND maxLat>=?",
        (lon, lon, lat, lat)).fetchall()
    if not rows:
        return None
    ids = [r[0] for r in rows]
    ph = ",".join("?" * len(ids))
    best, best_area = None, -1.0
    for r in car_conn.execute(
        "SELECT cod_imovel, area, json(geom) AS g FROM car_data WHERE id IN ({})".format(ph),
        ids):
        g = r[2]
        if not g:
            continue
        try:
            geom = shape(json.loads(g))
        except Exception:
            continue
        try:
            contains = geom.contains(Point(lon, lat))
        except Exception:  # noqa: BLE001 - invalid geometry → not contained
            contains = False
        if contains:
            area = float(r[1] or 0)
            if area > best_area:
                best_area = area
                best = r[0]
    return str(best).upper() if best else None


def resolve_car(df, car_db_path, enable_spatial=True):
    """Fill `cod_imovel`: explicit NRO_CAR when present; else spatial fallback.

    AUTESP has no CAR column, so the spatial fallback is its PRIMARY path. When
    car.db is unavailable and no explicit code exists, the row is left without
    cod_imovel (dropped downstream with a logged count — never crashes).
    Returns (out, counts).
    """
    out = df.copy()
    out["cod_imovel"] = ""
    explicit = out["nro_car"].notna() & (out["nro_car"] != "")
    out.loc[explicit, "cod_imovel"] = out.loc[explicit, "nro_car"].str.upper()

    need = (~explicit) & out["lat"].notna() & out["lon"].notna()
    counts = {"explicit_car": int(explicit.sum()),
              "spatial_needed": int(need.sum()), "spatial_resolved": 0}

    if counts["spatial_needed"] == 0 or not enable_spatial:
        return out, counts
    if not car_db_path or not os.path.exists(car_db_path):
        print("WARN: car.db not found at {} — spatial resolve skipped; rows "
              "without explicit CAR will be dropped".format(car_db_path))
        return out, counts

    conn = sqlite3.connect("file:{}?mode=ro".format(car_db_path), uri=True, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    try:
        for idx in out.index[need]:
            code = classify_point(conn, float(out.at[idx, "lon"]), float(out.at[idx, "lat"]))
            if code:
                out.at[idx, "cod_imovel"] = code
                counts["spatial_resolved"] += 1
    finally:
        conn.close()
    return out, counts


def write_db(df, out_path):
    """Write `sinaflor_auth.db` atomically via `<out>.tmp` + os.replace.

    A fresh single-file DB (DELETE journal mode): the runtime opens it with a
    `query_only=ON` handle, and the whole-file swap (like car.db) is safe under
    an existing reader. Only a fully-successful import replaces the target, so
    the DB file's mtime is the "marker after success" (common-mistake #5).
    """
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_name(out_path.name + ".tmp")
    conn = sqlite3.connect(tmp)
    try:
        conn.execute("PRAGMA journal_mode=DELETE")
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS sinaflor_auth (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                cod_imovel TEXT NOT NULL,
                nro_autorizacao TEXT,
                modo TEXT,
                data_inicio TEXT,
                data_fim TEXT,
                uf TEXT,
                municipio TEXT,
                situacao TEXT,
                lat REAL,
                lon REAL
            );
        """)
        # Explicit column list: the canonical DataFrame also carries `nro_car`
        # (source-of-truth only), which is NOT stored — only resolved cod_imovel.
        cols = ["cod_imovel", "nro_autorizacao", "modo", "data_inicio", "data_fim",
                "uf", "municipio", "situacao", "lat", "lon"]
        rows = list(df[cols].itertuples(index=False, name=None))
        sql = ("INSERT INTO sinaflor_auth "
               "(cod_imovel, nro_autorizacao, modo, data_inicio, data_fim, uf, "
               "municipio, situacao, lat, lon) VALUES (?,?,?,?,?,?,?,?,?,?)")
        for i in range(0, len(rows), BATCH):
            conn.executemany(sql, rows[i:i + BATCH])
        conn.commit()
        conn.execute("CREATE INDEX IF NOT EXISTS idx_sinaflor_cod "
                     "ON sinaflor_auth(cod_imovel)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_sinaflor_window "
                     "ON sinaflor_auth(cod_imovel, data_inicio, data_fim)")
        conn.commit()
        # VACUUM must run OUTSIDE any transaction (Python sqlite3 opens an
        # implicit one on DML) — the explicit commits above close it.
        conn.execute("VACUUM")
        conn.commit()
    finally:
        conn.close()
    os.replace(tmp, out_path)
    return len(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--window", type=int, default=730,
                    help="keep authorizations with DATA_DE_VALIDADE >= today - window (days)")
    ap.add_argument("--today", default=None,
                    help="ISO date to anchor the window (deterministic tests)")
    ap.add_argument("--force", action="store_true",
                    help="re-download even when the DB is younger than 7 days")
    ap.add_argument("--ufs", nargs="*", default=None, help="UF filter (ex: MT PA)")
    ap.add_argument("--no-car-resolve", action="store_true",
                    help="skip the spatial CAR fallback (explicit NRO_CAR only)")
    ap.add_argument("--out", default="backend-lua/data/sinaflor/sinaflor_auth.db")
    args = ap.parse_args()

    today = date.fromisoformat(args.today) if args.today else date.today()
    out = Path(args.out)

    # Freshness guard: the DB mtime is the success marker; skip when recent.
    if out.exists() and not args.force:
        age_days = (time.time() - out.stat().st_mtime) / 86400
        if age_days < 7:
            print("sinaflor_auth.db is {:.1f} days old — skipping download "
                  "(use --force to re-download)".format(age_days))
            return 0

    car_db_path = os.environ.get("CAR_DB_PATH") or "backend-lua/data/car/car.db"

    packages = ckan_package_list()
    frames, dropped_total = [], {}
    for pkg in packages:
        print("[{}] discovering resource...".format(pkg["modo"]))
        url = ckan_resource_url(pkg["id"])
        dest = Path("/tmp/yvy_sinaflor_{}.csv".format(pkg["modo"].lower()))
        print("[{}] downloading {} -> {}".format(pkg["modo"], url, dest))
        download_csv(url, dest)
        df = pd.read_csv(dest, sep=detect_sep(dest), encoding="utf-8-sig",
                         dtype=str, low_memory=False)
        norm, dropped = normalize(df, pkg["modo"], today, args.window, args.ufs)
        frames.append(norm)
        for k, v in dropped.items():
            dropped_total[k] = dropped_total.get(k, 0) + v
        print("[{}] {} rows after normalize (drops: {})".format(
            pkg["modo"], len(norm), dropped))

    combined = pd.concat(frames, ignore_index=True)
    combined, car_counts = resolve_car(combined, car_db_path,
                                       enable_spatial=not args.no_car_resolve)

    before = len(combined)
    kept = combined[combined["cod_imovel"] != ""]
    no_car = before - len(kept)

    n = write_db(kept, out)
    by_modo = kept.groupby("modo")["cod_imovel"].count().to_dict()
    print("\n=== sinaflor_auth.db written to {} ===".format(out))
    print("rows: {} (drops: {}; rows without cod_imovel dropped: {})".format(
        n, dropped_total, no_car))
    print("by modo: {}".format(by_modo))
    print("car resolve: {}".format(car_counts))
    print("marker (db mtime): {}".format(date.fromtimestamp(out.stat().st_mtime)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - top-level abort without marker
        print("ERROR: {} — no DB written (previous sinaflor_auth.db, if any, "
              "is intact)".format(exc), file=sys.stderr)
        sys.exit(1)
