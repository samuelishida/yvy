#!/usr/bin/env python
from __future__ import annotations

import argparse
import asyncio
import html
import json
import random
import re
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.parse import urljoin, urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent

sys.path.insert(0, str(SCRIPT_DIR))
from browser_fallback import STEALTH_ARGS, STEALTH_SCRIPT, USER_AGENTS  # noqa: E402


DEFAULT_DBS = [
    PROJECT_DIR / "backend-lua" / "data" / "yvy.db",
]

IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".avif")
BAD_IMAGE_PARTS = (
    "logo",
    "icon",
    "avatar",
    "placeholder",
    "spacer",
    "pixel",
    "1x1",
    "data:image",
)


@dataclass
class Article:
    url: str
    data: dict


def normalize_image(candidate: str | None, base_url: str) -> str | None:
    if not candidate:
        return None
    candidate = html.unescape(candidate).strip().strip("\"'")
    if not candidate or candidate.lower() in {"none", "null", "undefined"} or candidate.startswith("data:"):
        return None
    if candidate.startswith("//"):
        candidate = "https:" + candidate
    candidate = urljoin(base_url, candidate)
    parsed = urlparse(candidate)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return None
    if parsed.path.lower().rstrip("/").endswith(("/none", "/null", "/undefined")):
        return None
    return candidate


def image_score(url: str, source: str) -> int:
    lowered = url.lower()
    score = 0
    if source in {"og", "twitter", "schema", "meta"}:
        score += 1000
    if source in {"background", "srcset"}:
        score += 70
    if any(ext in lowered for ext in IMAGE_EXTS):
        score += 30
    for bad in BAD_IMAGE_PARTS:
        if bad in lowered:
            score -= 200
    if lowered.rstrip("/").endswith(("/none", "/null", "/undefined")):
        score -= 1000
    size = re.search(r"(\d{3,5})x(\d{3,5})", lowered)
    if size:
        width = int(size.group(1))
        height = int(size.group(2))
        score += min((width * height) // 10000, 100)
    if "wp-content/uploads" in lowered or "static/planet" in lowered:
        score += 25
    return score


def best_image(candidates: Iterable[tuple[str | None, str]], base_url: str) -> str | None:
    ranked: list[tuple[int, str]] = []
    seen: set[str] = set()
    for candidate, source in candidates:
        image_url = normalize_image(candidate, base_url)
        if not image_url or image_url in seen:
            continue
        seen.add(image_url)
        ranked.append((image_score(image_url, source), image_url))
    if not ranked:
        return None
    ranked.sort(reverse=True)
    return ranked[0][1]


def extract_images_from_html(page_html: str, base_url: str) -> list[tuple[str, str]]:
    candidates: list[tuple[str, str]] = []
    meta_patterns = [
        (r'<meta[^>]+(?:property|name|itemprop)=["\']og:image(?::url)?["\'][^>]+content=["\']([^"\']+)["\']', "og"),
        (r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name|itemprop)=["\']og:image(?::url)?["\']', "og"),
        (r'<meta[^>]+(?:property|name)=["\']twitter:image(?::src)?["\'][^>]+content=["\']([^"\']+)["\']', "twitter"),
        (r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']twitter:image(?::src)?["\']', "twitter"),
        (r'<meta[^>]+itemprop=["\']image["\'][^>]+content=["\']([^"\']+)["\']', "schema"),
        (r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+itemprop=["\']image["\']', "schema"),
    ]
    for pattern, source in meta_patterns:
        candidates.extend((match, source) for match in re.findall(pattern, page_html, re.I | re.S))

    for match in re.findall(r'background-image\s*:\s*url\((["\']?)([^"\')]+)\1\)', page_html, re.I):
        candidates.append((match[1], "background"))

    for attr in ("src", "data-src", "data-lazy-src", "data-original"):
        pattern = rf'<img[^>]+{attr}=["\']([^"\']+)["\']'
        candidates.extend((match, attr) for match in re.findall(pattern, page_html, re.I | re.S))

    for srcset in re.findall(r'<img[^>]+srcset=["\']([^"\']+)["\']', page_html, re.I | re.S):
        for part in srcset.split(","):
            src = part.strip().split(" ")[0]
            if src:
                candidates.append((src, "srcset"))

    for json_image in re.findall(r'"image"\s*:\s*(?:"([^"]+)"|\[\s*"([^"]+)")', page_html, re.I):
        candidates.append((json_image[0] or json_image[1], "schema"))

    return [(normalize_image(value, base_url) or value, source) for value, source in candidates]


async def extract_images_from_dom(page) -> list[tuple[str, str]]:
    return await page.evaluate(
        """() => {
          const out = [];
          const add = (value, source) => { if (value) out.push([value, source]); };
          document.querySelectorAll('meta[property="og:image"], meta[property="og:image:url"], meta[name="twitter:image"], meta[name="twitter:image:src"], meta[itemprop="image"]')
            .forEach((el) => add(el.content || el.getAttribute('content'), 'meta'));
          document.querySelectorAll('[style*="background-image"]')
            .forEach((el) => {
              const inline = el.getAttribute('style') || '';
              const match = inline.match(/background-image\\s*:\\s*url\\((['"]?)(.*?)\\1\\)/i);
              add(match && match[2], 'background');
            });
          document.querySelectorAll('img').forEach((img) => {
            add(img.currentSrc || img.src, 'img');
            add(img.dataset && (img.dataset.src || img.dataset.lazySrc || img.dataset.original), 'img');
            if (img.srcset) {
              img.srcset.split(',').forEach((part) => add(part.trim().split(/\\s+/)[0], 'srcset'));
            }
          });
          return out;
        }"""
    )


def known_db_paths() -> list[Path]:
    return [path for path in DEFAULT_DBS if path.exists()]


def connect_db(path: Path) -> sqlite3.Connection:
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=5000")
    con.execute("PRAGMA journal_mode=WAL")
    return con


def load_missing_articles(con: sqlite3.Connection, urls: list[str], limit: int) -> list[Article]:
    params: list[object] = []
    where = """(
        json_extract(data, '$.urlToImage') IS NULL
        OR json_extract(data, '$.urlToImage') = ''
        OR lower(json_extract(data, '$.urlToImage')) LIKE '%/none'
        OR lower(json_extract(data, '$.urlToImage')) LIKE '%/null'
        OR lower(json_extract(data, '$.urlToImage')) LIKE '%/undefined'
    )"""
    if urls:
        placeholders = ",".join("?" for _ in urls)
        where += f" AND url IN ({placeholders})"
        params.extend(urls)
    sql = f"""
        SELECT url, json(data) AS data_json
        FROM news
        WHERE {where}
        ORDER BY publishedAt DESC
    """
    if limit > 0:
        sql += " LIMIT ?"
        params.append(limit)
    articles: list[Article] = []
    for row in con.execute(sql, params):
        try:
            data = json.loads(row["data_json"])
        except Exception:
            data = {}
        articles.append(Article(url=row["url"], data=data))
    return articles


def update_image(con: sqlite3.Connection, article: Article, image_url: str) -> None:
    article.data["urlToImage"] = image_url
    payload = json.dumps(article.data, ensure_ascii=False)
    cursor = con.execute("UPDATE news SET data = jsonb(?) WHERE url = ?", (payload, article.url))
    if cursor.rowcount <= 0:
        raise RuntimeError(f"no row updated for {article.url}")


async def fetch_page_image(context, url: str, timeout_ms: int) -> tuple[str | None, int, str]:
    page = await context.new_page()
    await page.set_extra_http_headers(
        {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.8",
            "Upgrade-Insecure-Requests": "1",
        }
    )

    async def route_handler(route):
        if route.request.resource_type in {"font", "media"}:
            await route.abort()
            return
        await route.continue_()

    await page.route("**/*", route_handler)
    try:
        response = await page.goto(url, wait_until="domcontentloaded", timeout=timeout_ms)
        await page.wait_for_timeout(1800)
        try:
            await page.wait_for_load_state("networkidle", timeout=5000)
        except Exception:
            pass
        status = response.status if response else 0
        final_url = page.url
        page_html = await page.content()
        candidates = extract_images_from_html(page_html, final_url)
        candidates.extend(await extract_images_from_dom(page))
        return best_image(candidates, final_url), status, final_url
    finally:
        await page.close()


async def backfill_db(path: Path, args: argparse.Namespace) -> tuple[int, int, int]:
    from playwright.async_api import async_playwright

    con = connect_db(path)
    articles = load_missing_articles(con, args.url, args.limit)
    print(f"\nDB {path}")
    print(f"missing {len(articles)}")
    if not articles:
        con.close()
        return 0, 0, 0

    updated = 0
    failed = 0
    processed = 0
    ua = random.choice(USER_AGENTS)
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True, args=STEALTH_ARGS)
        context = await browser.new_context(
            user_agent=ua,
            locale="pt-BR",
            timezone_id="America/Sao_Paulo",
            viewport={"width": 1920, "height": 1080},
            device_scale_factor=1,
            color_scheme="light",
        )
        await context.add_init_script(STEALTH_SCRIPT)

        for idx, article in enumerate(articles, start=1):
            short = article.url if len(article.url) <= 88 else article.url[:85] + "..."
            print(f"[{idx}/{len(articles)}] {short}", end=" => ", flush=True)
            image_url, status, final_url = await fetch_page_image(context, article.url, args.timeout * 1000)
            processed += 1
            if not image_url:
                failed += 1
                print(f"NO IMAGE status={status} final={final_url}")
                continue
            if args.dry_run:
                updated += 1
                print(f"WOULD SET status={status} image={image_url}")
            else:
                update_image(con, article, image_url)
                updated += 1
                print(f"OK status={status} image={image_url}")
                if updated % 10 == 0:
                    con.commit()

        await context.close()
        await browser.close()

    if args.dry_run:
        con.rollback()
    else:
        con.commit()
        con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    con.close()
    print(f"result processed={processed} updated={updated} failed={failed}")
    return processed, updated, failed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Backfill missing news urlToImage via Playwright stealth.")
    parser.add_argument("--db", action="append", type=Path, help="SQLite DB path. Repeatable.")
    parser.add_argument("--url", action="append", default=[], help="Only process specific article URL. Repeatable.")
    parser.add_argument("--limit", type=int, default=0, help="Max rows per DB. 0 = all.")
    parser.add_argument("--timeout", type=int, default=45, help="Page timeout seconds.")
    parser.add_argument("--dry-run", action="store_true", help="Do not write DB.")
    return parser.parse_args()


async def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    args = parse_args()
    dbs = args.db or known_db_paths()
    if not dbs:
        print("no DB found", file=sys.stderr)
        return 1

    total_failed = 0
    for path in dbs:
        if not path.exists():
            print(f"skip missing DB {path}")
            continue
        _, _, failed = await backfill_db(path, args)
        total_failed += failed
    return 1 if total_failed else 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
