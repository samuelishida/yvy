"""Fire and environmental alert generation.

Produces 6 alert types from FIRMS fires, indigenous/conservation polygon data,
deforestation records, and WAQI air quality stations:

  cluster          — 5+ high/nominal fires within 15 km (24h)
  night_fire       — 3+ fires between 18:00–06:00 within 10 km (12h)
  indigenous_land  — any fire inside a Terra Indígena
  conservation_unit— any fire inside a UC ICMBio
  prodes           — deforestation records exist in DB
  pm25             — PM2.5 > 55 µg/m³ at any monitored station
"""
from __future__ import annotations

import datetime
import logging
import math
from typing import Any

import httpx

import biome_lookup
import conservation_units_lookup
import indigenous_lands_lookup

logger = logging.getLogger(__name__)

# ── Constants ──────────────────────────────────────────────────────────────

_CLUSTER_RADIUS_KM    = 15.0
_CLUSTER_MIN_FIRES    = 5
_CLUSTER_WINDOW_HOURS = 24

_NIGHT_RADIUS_KM      = 10.0
_NIGHT_MIN_FIRES      = 3
_NIGHT_WINDOW_HOURS   = 12
_NIGHT_START_HHMM     = 1800
_NIGHT_END_HHMM       = 600

_PM25_THRESHOLD       = 55      # µg/m³ (WHO 24-h guideline)
_MAX_ALERTS           = 20      # cap to avoid overwhelming the UI

# WAQI station IDs for major Brazilian cities (state · city)
_WAQI_STATIONS: list[tuple[str, str, str]] = [
    ("AC", "Rio Branco",    "rio-branco"),
    ("RO", "Porto Velho",   "porto-velho"),
    ("MT", "Cuiabá",        "cuiaba"),
    ("AM", "Manaus",        "manaus"),
    ("PA", "Belém",         "belem"),
    ("MA", "São Luís",      "sao-luis"),
    ("MS", "Campo Grande",  "campo-grande"),
    ("TO", "Palmas",        "palmas"),
    ("GO", "Goiânia",       "goiania"),
    ("DF", "Brasília",      "brasilia"),
]


# ── Geometry helpers ───────────────────────────────────────────────────────

def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    R = 6371.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _meta_for_fire(lat: float, lon: float) -> str:
    """Best human-readable location label: biome name."""
    biome = biome_lookup.classify_point(lat, lon)
    return biome or "Brasil"


# ── Time utilities ─────────────────────────────────────────────────────────

def _parse_fire_time(fire: dict) -> datetime.datetime | None:
    """Parse acq_date + acq_time into a UTC datetime, or None."""
    acq_date = fire.get("acq_date", "")
    acq_time = fire.get("acq_time", "")
    try:
        hhmm = int(acq_time) if acq_time else 0
        hh, mm = divmod(hhmm, 100)
        return datetime.datetime(
            *map(int, acq_date.split("-")), hh, mm,
            tzinfo=datetime.timezone.utc,
        )
    except Exception:
        return None


def _is_night(acq_time: str) -> bool:
    """Return True if acquisition time is between 18:00 and 06:00 UTC."""
    try:
        t = int(acq_time)
        return t >= _NIGHT_START_HHMM or t < _NIGHT_END_HHMM
    except (ValueError, TypeError):
        return False


def _ts_label(generated_at: datetime.datetime) -> str:
    """Human-readable relative time string (e.g., '2m', '1h', '3d')."""
    delta = datetime.datetime.now(datetime.timezone.utc) - generated_at
    total_s = int(delta.total_seconds())
    if total_s < 3600:
        return f"{max(1, total_s // 60)}m"
    if total_s < 86400:
        return f"{total_s // 3600}h"
    return f"{total_s // 86400}d"


# ── Clustering ─────────────────────────────────────────────────────────────

def _cluster_fires(
    candidates: list[dict],
    radius_km: float,
    min_count: int,
    window_hours: float,
) -> list[list[dict]]:
    """Return clusters of fires (each cluster is a list of fire dicts).

    Greedy O(n²) — fast enough for ≤5000 candidates.
    """
    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(hours=window_hours)

    recent = []
    for f in candidates:
        t = _parse_fire_time(f)
        if t is None or t >= cutoff:
            recent.append(f)

    assigned = [False] * len(recent)
    clusters: list[list[dict]] = []

    for i, seed in enumerate(recent):
        if assigned[i]:
            continue
        cluster = [seed]
        assigned[i] = True
        for j, other in enumerate(recent):
            if assigned[j]:
                continue
            if _haversine_km(seed["lat"], seed["lon"], other["lat"], other["lon"]) <= radius_km:
                cluster.append(other)
                assigned[j] = True
        if len(cluster) >= min_count:
            clusters.append(cluster)

    clusters.sort(key=lambda c: len(c), reverse=True)
    return clusters


# ── Alert generators ───────────────────────────────────────────────────────

def _cluster_alerts(fires: list[dict]) -> list[dict]:
    candidates = [
        f for f in fires
        if f.get("confidence", "").lower() in ("high", "nominal", "h", "n")
    ]
    clusters = _cluster_fires(candidates, _CLUSTER_RADIUS_KM, _CLUSTER_MIN_FIRES, _CLUSTER_WINDOW_HOURS)
    now = datetime.datetime.now(datetime.timezone.utc)
    alerts = []
    for cluster in clusters[:5]:
        centroid_lat = sum(f["lat"] for f in cluster) / len(cluster)
        centroid_lon = sum(f["lon"] for f in cluster) / len(cluster)
        meta = _meta_for_fire(centroid_lat, centroid_lon)
        alerts.append({
            "id": f"cluster_{centroid_lat:.2f}_{centroid_lon:.2f}",
            "type": "cluster",
            "tick": "crit",
            "meta": meta,
            "state": f"{len(cluster)} focos",
            "generated_at": now.isoformat(),
            "ts": _ts_label(now),
        })
    return alerts


def _night_fire_alerts(fires: list[dict]) -> list[dict]:
    candidates = [f for f in fires if _is_night(f.get("acq_time", ""))]
    clusters = _cluster_fires(candidates, _NIGHT_RADIUS_KM, _NIGHT_MIN_FIRES, _NIGHT_WINDOW_HOURS)
    now = datetime.datetime.now(datetime.timezone.utc)
    alerts = []
    for cluster in clusters[:5]:
        centroid_lat = sum(f["lat"] for f in cluster) / len(cluster)
        centroid_lon = sum(f["lon"] for f in cluster) / len(cluster)
        meta = _meta_for_fire(centroid_lat, centroid_lon)
        alerts.append({
            "id": f"night_{centroid_lat:.2f}_{centroid_lon:.2f}",
            "type": "night_fire",
            "tick": "warn",
            "meta": meta,
            "state": f"{len(cluster)} focos",
            "generated_at": now.isoformat(),
            "ts": _ts_label(now),
        })
    return alerts


def _indigenous_land_alerts(fires: list[dict]) -> list[dict]:
    if not indigenous_lands_lookup._lands:
        return []
    now = datetime.datetime.now(datetime.timezone.utc)
    by_ti: dict[str, dict] = {}
    for fire in fires:
        info = indigenous_lands_lookup.classify_point(fire["lon"], fire["lat"])
        if info:
            name = info["name"]
            if name not in by_ti:
                by_ti[name] = {"info": info, "count": 0}
            by_ti[name]["count"] += 1

    alerts = []
    for ti_name, data in sorted(by_ti.items(), key=lambda x: -x[1]["count"])[:5]:
        info = data["info"]
        state_abbr = info.get("state_abbr", "BR")
        state_name = info.get("state_name", "Brasil")
        meta = f"{state_name} · {ti_name}"
        alerts.append({
            "id": f"ti_{ti_name[:20].replace(' ', '_')}",
            "type": "indigenous_land",
            "tick": "crit",
            "meta": meta,
            "state": f"{state_abbr} · {data['count']} focos",
            "generated_at": now.isoformat(),
            "ts": _ts_label(now),
        })
    return alerts


def _conservation_unit_alerts(fires: list[dict]) -> list[dict]:
    if not conservation_units_lookup._units:
        return []
    now = datetime.datetime.now(datetime.timezone.utc)
    by_uc: dict[str, dict] = {}
    for fire in fires:
        info = conservation_units_lookup.classify_point(fire["lon"], fire["lat"])
        if info:
            name = info["name"]
            if name not in by_uc:
                by_uc[name] = {"info": info, "count": 0}
            by_uc[name]["count"] += 1

    alerts = []
    for uc_name, data in sorted(by_uc.items(), key=lambda x: -x[1]["count"])[:5]:
        info = data["info"]
        state_abbr = info.get("state_abbr", "BR")
        category = info.get("category", "UC")
        meta = f"{category} · {uc_name[:30]}"
        alerts.append({
            "id": f"uc_{uc_name[:20].replace(' ', '_')}",
            "type": "conservation_unit",
            "tick": "crit",
            "meta": meta,
            "state": f"{state_abbr} · {data['count']} focos",
            "generated_at": now.isoformat(),
            "ts": _ts_label(now),
        })
    return alerts


async def _prodes_alerts() -> list[dict]:
    """Generate an info alert when deforestation data is present in DB."""
    try:
        import db_sqlite
        records = await db_sqlite.find_deforestation(
            sw_lat=-34.0, ne_lat=5.5, sw_lng=-74.0, ne_lng=-34.0, limit=10
        )
        if not records:
            return []
        now = datetime.datetime.now(datetime.timezone.utc)
        # Approximate state from first deforested point
        first = records[0]
        meta = _meta_for_fire(first["lat"], first["lon"])
        # Rough area estimate: each PRODES sample ≈ 2 km²
        area_km2 = round(len(records) * 2)
        return [{
            "id": "prodes_latest",
            "type": "prodes",
            "tick": "info",
            "meta": meta,
            "state": f"{area_km2} km²",
            "generated_at": now.isoformat(),
            "ts": _ts_label(now),
        }]
    except Exception as exc:
        logger.warning("PRODES alert error: %s", exc)
        return []


async def _pm25_alerts(http_client: httpx.AsyncClient, waqi_token: str) -> list[dict]:
    now = datetime.datetime.now(datetime.timezone.utc)

    async def _fetch_one(state_abbr: str, city: str, station: str) -> dict | None:
        try:
            url = f"https://api.waqi.info/feed/{station}/?token={waqi_token}"
            resp = await http_client.get(url, timeout=8)
            data = resp.json()
            if data.get("status") != "ok":
                return None
            pm25 = data["data"].get("iaqi", {}).get("pm25", {}).get("v")
            if pm25 is None or float(pm25) < _PM25_THRESHOLD:
                return None
            return {
                "id": f"pm25_{station}",
                "type": "pm25",
                "tick": "warn",
                "meta": f"{state_abbr} · {city}",
                "state": f"{state_abbr} · {pm25} µg/m³",
                "generated_at": now.isoformat(),
                "ts": _ts_label(now),
            }
        except Exception as exc:
            logger.debug("PM2.5 query failed for %s: %s", station, exc)
            return None

    import asyncio
    results = await asyncio.gather(*[_fetch_one(*s) for s in _WAQI_STATIONS])
    return [r for r in results if r is not None]


# ── Public API ─────────────────────────────────────────────────────────────

async def generate_all_alerts(
    fires: list[dict[str, Any]],
    http_client: httpx.AsyncClient | None = None,
    waqi_token: str = "demo",
) -> dict[str, Any]:
    """Compute all alert types and return a structured response.

    Args:
        fires: List of fire dicts from db_sqlite.find_fires().
        http_client: Shared httpx.AsyncClient for PM2.5 queries.
        waqi_token: WAQI API token.

    Returns:
        {"alerts": [...], "count": N, "generated_at": ISO8601}
    """
    all_alerts: list[dict] = []

    # Fire-based alerts (CPU-bound, no I/O)
    all_alerts.extend(_cluster_alerts(fires))
    all_alerts.extend(_night_fire_alerts(fires))
    all_alerts.extend(_indigenous_land_alerts(fires))
    all_alerts.extend(_conservation_unit_alerts(fires))

    # Async I/O alerts
    all_alerts.extend(await _prodes_alerts())
    if http_client and waqi_token:
        all_alerts.extend(await _pm25_alerts(http_client, waqi_token))

    # Sort: crit first, then warn, then info; within each tier by id for stability
    tier = {"crit": 0, "warn": 1, "info": 2}
    all_alerts.sort(key=lambda a: (tier.get(a["tick"], 9), a["id"]))

    all_alerts = all_alerts[:_MAX_ALERTS]
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    return {"alerts": all_alerts, "count": len(all_alerts), "generated_at": now}
