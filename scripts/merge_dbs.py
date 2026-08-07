#!/usr/bin/env python3
"""merge_dbs.py — Merge a source SQLite DB into a target DB (union, dedup on natural keys).

Keeps the TARGET's version of rows that exist in both DBs; inserts SOURCE rows
that are missing from the target. After merging it checkpoints the WAL, VACUUMs
and runs PRAGMA optimize, then prints before/after counts and integrity check.

Tables merged (identical schema in both, from app/db.lua):
    fire_data  (key: lat, lon, acq_date)
    news       (key: url)
    lookup_data(key: key)
    deforestation_data (key: lat, lon — defensive; prod has 0 rows today)

Usage:
    python3 scripts/merge_dbs.py --target <merged.db> --source <other.db>
    # --target is mutated in place. Make a copy first if you need the original.

Safety: run while both DBs are NOT being written to (stop the app / use a snapshot).
"""
import argparse
import sqlite3
import sys

COLUMNS = {
    "fire_data": [
        "lat", "lon", "acq_date", "ingested_at", "data",
        "nature", "nature_evidence", "nature_at", "nature_version",
    ],
    "news": ["url", "publishedAt", "ingested_at", "data"],
    "deforestation_data": ["lat", "lon", "data"],
    "lookup_data": ["key", "data", "updated_at"],
}
NATURAL_KEYS = {
    "fire_data": ("lat", "lon", "acq_date"),
    "news": ("url",),
    "deforestation_data": ("lat", "lon"),
    "lookup_data": ("key",),
}
TABLE_NAMES = list(COLUMNS.keys())


def canonical_url(u: str) -> str:
    """Canonical news URL: strip fragment + trailing slashes (keep root '/')."""
    if not u:
        return u
    u = u.split("#", 1)[0]
    if len(u) > 1:
        u = u.rstrip("/")
    return u


def merge(source_path: str, target_path: str) -> dict:
    src = sqlite3.connect(source_path)
    tgt = sqlite3.connect(target_path)
    src.execute("PRAGMA query_only=ON")

    added = {}
    tgt.execute("BEGIN")
    for table in TABLE_NAMES:
        cols = COLUMNS[table]
        key_cols = ", ".join(NATURAL_KEYS[table])

        existing = set(tgt.execute(f"SELECT {key_cols} FROM {table}"))
        if table == "news":
            # Canonicalize so ".../a" and ".../a/" in different DBs don't both
            # survive the merge as separate rows (matches app/db.lua).
            existing = {tuple(canonical_url(k[0]) for k in e) for e in existing}

        to_insert = []
        for row in src.execute(f"SELECT {','.join(cols)} FROM {table}"):
            row = tuple(row)
            if table == "news":
                row = (canonical_url(row[0]),) + row[1:]
            key = tuple(row[i] for i in range(len(NATURAL_KEYS[table])))
            if key not in existing:
                to_insert.append(row)
                existing.add(key)  # avoid dupes within source too

        if to_insert:
            placeholders = ",".join("?" * len(cols))
            tgt.executemany(
                f"INSERT OR IGNORE INTO {table} ({','.join(cols)}) VALUES ({placeholders})",
                to_insert,
            )
        added[table] = len(to_insert)
    tgt.execute("COMMIT")

    # Compact / finalize. VACUUM must run outside a transaction.
    tgt.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    tgt.execute("VACUUM")
    tgt.execute("PRAGMA optimize")

    src.close()
    tgt.close()
    return added


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--target", required=True, help="DB to merge INTO (mutated in place)")
    ap.add_argument("--source", required=True, help="DB to pull rows FROM")
    args = ap.parse_args()

    def counts(path):
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        out = {t: con.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in TABLE_NAMES}
        con.close()
        return out

    print(f"before target {args.target}: {counts(args.target)}")
    print(f"before source {args.source}: {counts(args.source)}")

    added = merge(args.source, args.target)

    print(f"after  target {args.target}: {counts(args.target)}")
    print(f"added from source: {added}")

    # Final integrity check on the merged file.
    con = sqlite3.connect(f"file:{args.target}?mode=ro", uri=True)
    integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
    con.close()
    print(f"integrity_check: {integrity}")
    return 0 if integrity == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
