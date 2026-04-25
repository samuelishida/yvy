"""News module using SQLite instead of MongoDB."""
import asyncio
import os
import logging
from datetime import datetime, timedelta, timezone

import httpx

import db_sqlite

logger = logging.getLogger(__name__)

NEWS_API_KEY = os.getenv("NEWS_API_KEY", "").strip()
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

_MYMEMORY_WARN_FRAGMENTS = (
    "MYMEMORY WARNING",
    "YOU USED ALL AVAILABLE FREE TRANSLATIONS",
    "NEXT AVAILABLE IN",
    "VISIT HTTPS://MYMEMORY.TRANSLATED.NET",
)


def _is_mymemory_warning(text: str) -> bool:
    """Return True if text is the MyMemory quota-exhaustion warning instead of a real translation."""
    if not text or len(text) < 200:
        return False
    text_upper = text.upper()
    return all(fragment in text_upper for fragment in _MYMEMORY_WARN_FRAGMENTS[:2])


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
        async with db_sqlite._get_conn() as conn:
            if urls_with_bad_title:
                placeholders = ",".join("?" for _ in urls_with_bad_title)
                await conn.execute(f"UPDATE news SET title_en = NULL WHERE url IN ({placeholders})", urls_with_bad_title)
            if urls_with_bad_desc:
                placeholders = ",".join("?" for _ in urls_with_bad_desc)
                await conn.execute(f"UPDATE news SET description_en = NULL WHERE url IN ({placeholders})", urls_with_bad_desc)
            await conn.commit()
            logger.info("Cleared corrupted MyMemory translations from %d / %d rows.", len(urls_with_bad_title), len(urls_with_bad_desc))
    except Exception as e:
        logger.error("Failed to clear bad EN fields from DB: %s", e)


async def _get_cached_translations(urls: list[str]) -> dict[str, dict]:
    """Lookup existing DB translations for URLs. Returns {url: {title_en, description_en}}."""
    if not urls:
        return {}
    placeholders = ",".join("?" for _ in urls)
    query = f"SELECT url, title_en, description_en FROM news WHERE url IN ({placeholders})"
    async with db_sqlite._get_conn() as conn:
        cursor = await conn.execute(query, urls)
        rows = await cursor.fetchall()
    return {
        r["url"]: {
            "title_en": r["title_en"],
            "description_en": r["description_en"],
        }
        for r in rows if r["title_en"] or r["description_en"]
    }


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

async def fetch_and_save_news():
    if not NEWS_API_KEY:
        logger.warning("NEWS_API_KEY not configured. Skipping news fetch.")
        return []

    try:
        if await has_recent_news():
            logger.info("Recent news already available. Skipping fetch.")
            return await db_sqlite.get_news_page(page=1, page_size=20)

        logger.info("Fetching news from NewsAPI...")
        client = _get_client()
        resp = await client.get(
            NEWS_API_BASE_URL + "/everything",
            params={
                "q": 'environment OR sustainability OR ecology OR climate OR "meio ambiente" OR sustentabilidade OR ecologia OR biodiversidade',
                "language": "pt",
                "sortBy": "publishedAt",
                "pageSize": 10,
                "apiKey": NEWS_API_KEY,
            },
        )
        resp.raise_for_status()
        response = resp.json()

        articles = response.get("articles", [])
        if not articles:
            logger.info("No articles found.")
            return []

        now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()

        # Normalize API articles to consistent dict keys
        for a in articles:
            a["title"] = (a.get("title") or "").strip()
            a["description"] = (a.get("description") or "").strip()

        # --- Look for existing DB rows for these URLs ---
        urls = [a.get("url", "") for a in articles]
        cached = await _get_cached_translations(urls)

        # --- Scan existing DB rows for corrupted MyMemory warnings ---
        # If any have bad title_en/description_en, clear them so they get re-translated now.
        existing_bad_title_urls = []
        existing_bad_desc_urls = []
        for url, vals in cached.items():
            te = vals.get("title_en", "") or ""
            de = vals.get("description_en", "") or ""
            if _is_mymemory_warning(te):
                existing_bad_title_urls.append(url)
            if _is_mymemory_warning(de):
                existing_bad_desc_urls.append(url)
        if existing_bad_title_urls or existing_bad_desc_urls:
            logger.warning("Found %d titles + %d descriptions with MyMemory warnings in DB. Clearing for re-translation.",
                           len(existing_bad_title_urls), len(existing_bad_desc_urls))
            await _wipe_bad_en_from_db(existing_bad_title_urls, existing_bad_desc_urls)
            # Refresh the cache after clearing
            cached = await _get_cached_translations(urls)

        # --- Build list of texts that still need translation ---
        texts_to_translate = []
        translate_map = []  # [(article_index, field)]
        for i, article in enumerate(articles):
            cached_en = cached.get(article.get("url", ""), {})
            title = article.get("title", "")
            description = article.get("description", "")

            if cached_en.get("title_en"):
                article["title_en"] = cached_en["title_en"]
            elif title:
                texts_to_translate.append(title)
                translate_map.append((i, "title"))

            if cached_en.get("description_en"):
                article["description_en"] = cached_en["description_en"]
            elif description:
                texts_to_translate.append(description)
                translate_map.append((i, "description"))

        if texts_to_translate:
            translations = await batch_translate(texts_to_translate, "pt", "en")
            for idx, (article_i, field) in enumerate(translate_map):
                val = translations.get(idx, "")
                if val and not _is_mymemory_warning(val):
                    articles[article_i][f"{field}_en"] = val

        processed = []
        for article in articles:
            if not article.get("title"):
                extracted = extract_title_from_url(article.get("url", ""))
                article["title"] = extracted or (article.get("description", "")[:50] + "..." if article.get("description") else "#")
            article["ingested_at"] = now_iso
            processed.append(article)

        await db_sqlite.bulk_upsert_news(processed)

        logger.info("Processed %d articles.", len(articles))
        return await db_sqlite.get_news_page(page=1, page_size=20)
    except httpx.HTTPStatusError as e:
        logger.error("NewsAPI HTTP error: %s", e)
        return await db_sqlite.get_news_page(page=1, page_size=20)
    except Exception as e:
        logger.error("Error fetching/saving news: %s", e)
        return []


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

async def get_news(page=1, page_size=20, lang="pt"):
    try:
        articles = await db_sqlite.get_news_page(page, page_size)

        bad_title_urls = []
        bad_desc_urls = []

        for article in articles:
            article["_id"] = str(hash(article.get("url", "")))
            _clear_bad_en(article)

            # If EN was bad, also collect for async DB wipe
            if article.pop("title_en_bad", False):
                bad_title_urls.append(article["url"])
            if article.pop("description_en_bad", False):
                bad_desc_urls.append(article["url"])

            if lang == "en":
                if article.get("title_en"):
                    article["title"] = article["title_en"]
                if article.get("description_en"):
                    article["description"] = article["description_en"]

        if bad_title_urls or bad_desc_urls:
            # Fire-and-forget: clean DB in background so next sync re-translates
            asyncio.get_event_loop().create_task(
                _wipe_bad_en_from_db(bad_title_urls, bad_desc_urls)
            )

        return articles
    except Exception as e:
        logger.error("Error fetching news from DB: %s", e)
        return []


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
