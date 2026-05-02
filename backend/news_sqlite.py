"""News module using SQLite instead of MongoDB."""
import asyncio
import os
import re
import logging
from datetime import datetime, timedelta, timezone

import httpx

import db_sqlite

logger = logging.getLogger(__name__)

NEWS_API_KEY = os.getenv("NEWS_API_KEY", "").strip()
NEWS_SCRAPER_ENABLED = os.getenv("NEWS_SCRAPER_ENABLED", "1") == "1"
NEWS_SCRAPER_FALLBACK_THRESHOLD = int(os.getenv("NEWS_SCRAPER_FALLBACK_THRESHOLD", "5"))
NEWS_API_BASE_URL = "https://newsapi.org/v2"
MYMEMORY_API_URL = "https://api.mymemory.translated.net/get"

_http_client: httpx.AsyncClient | None = None


def _get_client() -> httpx.AsyncClient:
    global _http_client
    if _http_client is None:
        _http_client = httpx.AsyncClient(timeout=httpx.Timeout(15.0))
    return _http_client


async def close_http_client() -> None:
    global _http_client
    if _http_client:
        await _http_client.aclose()
        _http_client = None


async def has_recent_news():
    return await db_sqlite.has_recent_news(minutes=15)


# ---------------------------------------------------------------------------
# MyMemory warning detection
# ---------------------------------------------------------------------------

# Regex matches the MyMemory quota-exhaustion warning (handles newlines, case-insensitive, varying digits)
_MYMEMORY_WARNING_RE = re.compile(
    r"MYMEMORY\s+WARNING.*YOU\s+USED\s+ALL\s+AVAILABLE\s+FREE\s+TRANSLATIONS.*NEXT\s+AVAILABLE\s+IN",
    re.IGNORECASE | re.DOTALL,
)


def _is_mymemory_warning(text: str) -> bool:
    """Return True if text is the MyMemory quota-exhaustion warning instead of a real translation."""
    if not text:
        return False
    return bool(_MYMEMORY_WARNING_RE.search(text))


def _clear_bad_en(article: dict) -> None:
    """Null out title_en/description_en when they contain MyMemory warning text."""
    if article.get("title_en") and _is_mymemory_warning(article["title_en"]):
        logger.warning("Detected MyMemory warning in title_en (%s). Clearing.", article.get("url", ""))
        article["title_en"] = None
        article["title_en_bad"] = True  # marker so caller knows to re-translate
    if article.get("description_en") and _is_mymemory_warning(article["description_en"]):
        logger.warning("Detected MyMemory warning in description_en (%s). Clearing.", article.get("url", ""))
        article["description_en"] = None
        article["description_en_bad"] = True


async def _wipe_bad_en_from_db(urls_with_bad_title: list[str], urls_with_bad_desc: list[str]) -> None:
    """Clear corrupted MyMemory warning strings from DB so next fetch re-translates via fallbacks."""
    if not urls_with_bad_title and not urls_with_bad_desc:
        return
    try:
        all_urls = list(set(urls_with_bad_title + urls_with_bad_desc))
        fields_to_clear = []
        if urls_with_bad_title:
            fields_to_clear.append("title_en")
        if urls_with_bad_desc:
            fields_to_clear.append("description_en")
        await db_sqlite.clear_news_fields(all_urls, fields_to_clear)
        logger.info("Cleared corrupted MyMemory translations from %d / %d rows.", len(urls_with_bad_title), len(urls_with_bad_desc))
    except Exception as e:
        logger.error("Failed to clear bad EN fields from DB: %s", e)


async def _repair_bad_translations(limit: int = 50) -> dict:
    """Retroactively repair corrupted or missing EN translations in DB.
    
    1. Find up to `limit` rows where title_en or description_en is either:
       - containing MyMemory warning text (corrupted)
       - NULL or empty (never translated, likely because MyMemory was exhausted at fetch)
    2. Wipe bad fields.
    3. Re-translate PT title/description via fallback chain (Libre, Google).
    4. Save back to DB.
    
    Returns {"repaired": int, "failed": int, "skipped": int}.
    """
    repaired = 0
    failed = 0
    skipped = 0
    
    try:
        async with db_sqlite._get_conn() as conn:
            # Find rows where either title_en OR description_en is bad or missing
            # Using json_extract on the JSONB data column
            cursor = await conn.execute(
                """
                SELECT url, json_extract(data, '$.title') AS title,
                       json_extract(data, '$.description') AS description,
                       json_extract(data, '$.title_en') AS title_en,
                       json_extract(data, '$.description_en') AS description_en
                FROM news
                WHERE (json_extract(data, '$.title_en') IS NULL OR json_extract(data, '$.title_en') = '' OR json_extract(data, '$.title_en') LIKE '%MYMEMORY WARNING%')
                   OR (json_extract(data, '$.description_en') IS NULL OR json_extract(data, '$.description_en') = '' OR json_extract(data, '$.description_en') LIKE '%MYMEMORY WARNING%')
                ORDER BY publishedAt DESC
                LIMIT ?
                """,
                (limit,),
            )
            rows = await cursor.fetchall()
    except Exception as e:
        logger.error("Failed querying bad translations: %s", e)
        return {"repaired": 0, "failed": 0, "skipped": 0}

    if not rows:
        return {"repaired": 0, "failed": 0, "skipped": 0}

    logger.info("Found %d rows needing EN translation repair. Repairing...", len(rows))
    
    chain = TranslatorChain()
    semaphore = asyncio.Semaphore(3)
    
    async def repair_row(row):
        nonlocal repaired, failed, skipped
        url = row["url"]
        pt_title = (row["title"] or "").strip()
        pt_desc = (row["description"] or "").strip()
        old_te = row["title_en"] or ""
        old_de = row["description_en"] or ""
        
        # A field is "bad" if it's a MyMemory warning OR if it's NULL/empty
        te_bad = _is_mymemory_warning(old_te) or (not old_te)
        de_bad = _is_mymemory_warning(old_de) or (not old_de)
        
        if not te_bad and not de_bad:
            skipped += 1
            return
        
        new_te = old_te
        new_de = old_de
        
        async with semaphore:
            if te_bad and pt_title:
                new_te = await chain.translate(pt_title, "pt", "en")
                if not new_te:
                    logger.warning("Repair failed for title: %s", url)
            if de_bad and pt_desc:
                new_de = await chain.translate(pt_desc, "pt", "en")
                if not new_de:
                    logger.warning("Repair failed for description: %s", url)
        
        if new_te and not _is_mymemory_warning(new_te):
            final_te = new_te
        else:
            final_te = None
        if new_de and not _is_mymemory_warning(new_de):
            final_de = new_de
        else:
            final_de = None
        
        # Only write back if we actually got a good translation
        if not final_te and not final_de:
            failed += 1
            return
        
        try:
            updates = {}
            if final_te:
                updates["title_en"] = final_te
            if final_de:
                updates["description_en"] = final_de
            await db_sqlite.update_news_fields(url, updates)
            repaired += 1
            logger.info("Repaired translations for %s (te=%s, de=%s)", url, bool(final_te), bool(final_de))
        except Exception as e:
            logger.error("DB update failed for %s: %s", url, e)
            failed += 1
    
    await asyncio.gather(*(repair_row(r) for r in rows))
    
    logger.info("Repair complete: %d repaired, %d failed, %d skipped (from %d candidates).",
                repaired, failed, skipped, len(rows))
    return {"repaired": repaired, "failed": failed, "skipped": skipped}


async def _get_cached_translations(urls: list[str]) -> dict[str, dict]:
    """Lookup existing DB translations for URLs. Returns {url: {title_en, description_en}}."""
    if not urls:
        return {}
    return await db_sqlite.get_news_fields_by_urls(urls, ["title_en", "description_en"])


# ---------------------------------------------------------------------------
# Translation chain
# ---------------------------------------------------------------------------

class TranslatorChain:
    """Multi-provider translation chain: MyMemory -> LibreTranslate -> Google Translate."""

    def __init__(self):
        self._mymemory_quota_exhausted = False

    async def translate(self, text: str, source_lang: str, target_lang: str) -> str:
        if not text:
            return ""

        if not self._mymemory_quota_exhausted:
            result = await self._try_mymemory(text, source_lang, target_lang)
            if result and not _is_mymemory_warning(result):
                return result

        result = await self._try_libre(text, source_lang, target_lang)
        if result:
            return result

        result = await self._try_google(text, source_lang, target_lang)
        if result:
            return result

        return ""

    async def _try_mymemory(self, text, source_lang, target_lang) -> str | None:
        try:
            client = _get_client()
            resp = await client.get(
                MYMEMORY_API_URL,
                params={"q": text[:500], "langpair": f"{source_lang}|{target_lang}"},
            )
            data = resp.json()
            status = data.get("responseStatus")
            translation = data.get("responseData", {}).get("translatedText", "")

            if status != 200 or not translation:
                return None

            if _is_mymemory_warning(translation):
                self._mymemory_quota_exhausted = True
                logger.warning("MyMemory quota exhausted (warning text detected). Switching to fallbacks.")
                return None

            if translation.lower() == text.lower():
                return None
            return translation
        except Exception:
            return None

    async def _try_libre(self, text, source_lang, target_lang) -> str | None:
        try:
            client = _get_client()
            resp = await client.post(
                "https://libretranslate.de/translate",
                json={"q": text, "source": source_lang, "target": target_lang},
                headers={"Content-Type": "application/json"},
                timeout=httpx.Timeout(10.0),
            )
            if resp.status_code == 200:
                data = resp.json()
                translation = data.get("translatedText", "")
                if translation and translation.lower() != text.lower():
                    return translation
        except Exception:
            pass
        return None

    async def _try_google(self, text, source_lang, target_lang) -> str | None:
        try:
            client = _get_client()
            resp = await client.get(
                "https://translate.googleapis.com/translate_a/single",
                params={
                    "client": "gtx",
                    "sl": source_lang,
                    "tl": target_lang,
                    "dt": "t",
                    "q": text[:5000],
                },
                timeout=httpx.Timeout(10.0),
            )
            if resp.status_code == 200:
                data = resp.json()
                if (
                    data
                    and isinstance(data, list)
                    and len(data) > 0
                    and isinstance(data[0], list)
                    and len(data[0]) > 0
                    and isinstance(data[0][0], list)
                    and len(data[0][0]) > 0
                ):
                    translation = data[0][0][0]
                    if translation and translation.lower() != text.lower():
                        return translation
        except Exception:
            pass
        return None


# ---------------------------------------------------------------------------
# Fetch + save
# ---------------------------------------------------------------------------

async def _run_rss(client: "httpx.AsyncClient") -> list[dict]:
    """Run RSS scrapers and return articles (empty list if disabled or failed)."""
    if not NEWS_SCRAPER_ENABLED:
        logger.info("NEWS_SCRAPER_ENABLED=0 — skipping RSS scraper.")
        return []
    try:
        from news_scrapers import fetch_all_sources
        articles = await fetch_all_sources(client=client)
        logger.info(
            "RSS scraper yielded %d articles.", len(articles),
            extra={"event": "rss_scraper_done", "details": {"count": len(articles)}},
        )
        return articles
    except Exception as exc:
        logger.error("RSS scraper failed entirely: %s", exc, exc_info=True)
        return []


async def fetch_and_save_news():
    """Main news sync entry point.

    Runs RSS scrapers, applies a keyword relevance filter, then translates
    and saves to DB. No third-party news aggregator API required.
    """
    try:
        if await has_recent_news():
            logger.info("Recent news already available. Skipping fetch.")
            return await db_sqlite.get_news_page(page=1, page_size=20)

        client = _get_client()

        rss_articles = await _run_rss(client)

        seen_urls: set[str] = set()
        raw: list[dict] = []
        for a in rss_articles:
            url = a.get("url", "")
            if url and url not in seen_urls:
                seen_urls.add(url)
                raw.append(a)

        # ── Keyword relevance filter ─────────────────────────────────────────
        from news_scrapers import is_relevant
        before = len(raw)
        articles = [a for a in raw if is_relevant(a)]
        dropped = before - len(articles)
        if dropped:
            logger.info(
                "Keyword filter dropped %d/%d articles.", dropped, before,
                extra={"event": "news_keyword_filter",
                       "details": {"before": before, "after": len(articles), "dropped": dropped}},
            )

        if not articles:
            logger.info("No relevant articles found from any source.")
            return await db_sqlite.get_news_page(page=1, page_size=20)

        now_iso = datetime.now(timezone.utc).isoformat()

        # ── Translation: reuse cached EN translations where possible ─────────
        urls = [a.get("url", "") for a in articles]
        cached = await _get_cached_translations(urls)

        texts_to_translate: list[str] = []
        translate_map: list[tuple[int, str]] = []

        for i, article in enumerate(articles):
            cached_en = cached.get(article.get("url", ""), {})
            title = article.get("title", "")
            description = article.get("description", "")

            te = cached_en.get("title_en")
            de = cached_en.get("description_en")

            if te and not _is_mymemory_warning(te):
                article["title_en"] = te
            elif title:
                texts_to_translate.append(title)
                translate_map.append((i, "title"))

            if de and not _is_mymemory_warning(de):
                article["description_en"] = de
            elif description:
                texts_to_translate.append(description)
                translate_map.append((i, "description"))

        if texts_to_translate:
            translations = await batch_translate(texts_to_translate, "pt", "en")
            for idx, (article_i, field) in enumerate(translate_map):
                val = translations.get(idx, "")
                if val and not _is_mymemory_warning(val):
                    articles[article_i][f"{field}_en"] = val

        # ── Finalize & persist ────────────────────────────────────────────────
        processed = []
        for article in articles:
            if not article.get("title"):
                extracted = extract_title_from_url(article.get("url", ""))
                article["title"] = (
                    extracted
                    or (article.get("description", "")[:50] + "..."
                        if article.get("description") else "#")
                )
            article["ingested_at"] = now_iso
            processed.append(article)

        await db_sqlite.bulk_upsert_news(processed)

        # Background retroactive translation repair
        asyncio.get_event_loop().create_task(_repair_bad_translations(limit=50))

        logger.info(
            "News sync complete: %d articles saved.", len(processed),
            extra={"event": "news_sync_saved", "details": {"count": len(processed)}},
        )
        return await db_sqlite.get_news_page(page=1, page_size=20)

    except Exception as e:
        logger.error("Error in fetch_and_save_news: %s", e, exc_info=True)
        return await db_sqlite.get_news_page(page=1, page_size=20)


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

async def _save_en_to_db(articles: list[dict]) -> None:
    """Write translated EN fields back to DB via JSONB update helpers.
    Skips articles with no title_en or description_en."""
    if not articles:
        return
    count = 0
    for a in articles:
        updates = {}
        if a.get("title_en"):
            updates["title_en"] = a["title_en"]
        if a.get("description_en"):
            updates["description_en"] = a["description_en"]
        if updates:
            try:
                await db_sqlite.update_news_fields(a["url"], updates)
                count += 1
            except Exception:
                pass
    if count:
        logger.info("Saved EN translations for %d articles.", count)


async def get_news(page=1, page_size=20, lang="pt"):
    try:
        articles = await db_sqlite.get_news_page(page, page_size)

        bad_rows_seen = 0
        missing_en_rows = 0
        bad_title_urls = []
        bad_desc_urls = []

        for article in articles:
            article["_id"] = str(hash(article.get("url", "")))
            _clear_bad_en(article)

            # If EN was bad (corrupted MyMemory warning), collect for DB wipe
            if article.pop("title_en_bad", False):
                bad_title_urls.append(article["url"])
            if article.pop("description_en_bad", False):
                bad_desc_urls.append(article["url"])

            # Count rows with missing or corrupted EN
            te = article.get("title_en")
            de = article.get("description_en")
            if te is None or de is None or _is_mymemory_warning(te or "") or _is_mymemory_warning(de or ""):
                bad_rows_seen += 1
                if te is None or _is_mymemory_warning(te or ""):
                    missing_en_rows += 1

            if lang == "en":
                if article.get("title_en"):
                    article["title"] = article["title_en"]
                if article.get("description_en"):
                    article["description"] = article["description_en"]

        # --- Immediate on-demand EN translation for missing fields in this page (EN requests only) ---
        if lang == "en" and missing_en_rows > 0:
            texts_to_translate = []
            translate_map = []  # [(article_index, field)]
            for i, article in enumerate(articles):
                pt_title = (article.get("title") or "").strip()
                pt_desc = (article.get("description") or "").strip()
                if (not article.get("title_en") or _is_mymemory_warning(article.get("title_en", ""))) and pt_title:
                    texts_to_translate.append(pt_title)
                    translate_map.append((i, "title"))
                if (not article.get("description_en") or _is_mymemory_warning(article.get("description_en", ""))) and pt_desc:
                    texts_to_translate.append(pt_desc)
                    translate_map.append((i, "description"))

            if texts_to_translate:
                logger.info("On-demand EN translation for %d missing fields in page %d...", len(texts_to_translate), page)
                translations = await batch_translate(texts_to_translate, "pt", "en")
                for idx, (article_i, field) in enumerate(translate_map):
                    val = translations.get(idx, "")
                    if val and not _is_mymemory_warning(val):
                        articles[article_i][f"{field}_en"] = val
                        # Also swap in-memory for the current EN response
                        if field == "title" and articles[article_i].get("title_en"):
                            articles[article_i]["title"] = articles[article_i]["title_en"]
                        if field == "description" and articles[article_i].get("description_en"):
                            articles[article_i]["description"] = articles[article_i]["description_en"]
                # Save translated results back to DB
                asyncio.get_event_loop().create_task(_save_en_to_db(articles))

        if bad_title_urls or bad_desc_urls:
            asyncio.get_event_loop().create_task(
                _wipe_bad_en_from_db(bad_title_urls, bad_desc_urls)
            )
        
        if bad_rows_seen > 0:
            # Trigger background retroactive repair (larger batch than immediate)
            asyncio.get_event_loop().create_task(_repair_bad_translations(limit=bad_rows_seen + 10))

        return articles
    except Exception as e:
        logger.error("Error fetching news from DB: %s", e)
        return []


# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------

async def repair_all_bad_translations(limit: int = 500) -> dict:
    """Public entrypoint to retroactively repair all bad translations.
    Backend route can call this to force a deep repair.
    """
    return await _repair_bad_translations(limit=limit)


# ---------------------------------------------------------------------------
# Translation batch
# ---------------------------------------------------------------------------

async def batch_translate(texts, source_lang, target_lang):
    """Translate a batch of texts using TranslatorChain with concurrency throttling."""
    results = {}
    indices = [i for i, text in enumerate(texts) if text]
    if not indices:
        return {i: "" for i in range(len(texts))}

    chain = TranslatorChain()
    semaphore = asyncio.Semaphore(3)

    async def do_translate(idx):
        async with semaphore:
            results[idx] = await chain.translate(texts[idx], source_lang, target_lang)

    await asyncio.gather(*(do_translate(i) for i in indices))
    return results


def extract_title_from_url(url):
    try:
        path = url.split("/")[-1]
        if path:
            title = path.replace("-", " ").replace("_", " ")
            return title[:50] + "..." if len(title) > 50 else title
    except Exception:
        pass
    return ""
