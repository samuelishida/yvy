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


class TranslatorChain:
    """Multi-provider translation chain: MyMemory -> LibreTranslate -> Google Translate."""

    def __init__(self):
        self._mymemory_quota_exhausted = False

    async def translate(self, text: str, source_lang: str, target_lang: str) -> str:
        """Try MyMemory first, then LibreTranslate, then Google Translate free endpoint.
        Returns translated text or empty string if all fail."""
        if not text:
            return ""

        # 1) MyMemory (skip if we already know quota is exhausted)
        if not self._mymemory_quota_exhausted:
            result = await self._try_mymemory(text, source_lang, target_lang)
            if result:
                return result

        # 2) LibreTranslate (public instance, no key)
        result = await self._try_libre(text, source_lang, target_lang)
        if result:
            return result

        # 3) Google Translate free endpoint (gtx)
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

            # Detect quota-exhaustion in any form
            if status != 200 or not translation:
                return None
            if "YOU USED ALL AVAILABLE FREE TRANSLATIONS" in translation.upper():
                self._mymemory_quota_exhausted = True
                logger.warning("MyMemory daily quota exhausted. Switching to fallback translators.")
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

        # Pre-check DB for cached translations to avoid redundant MyMemory calls
        urls = [a.get("url", "") for a in articles]
        cached = await _get_cached_translations(urls)

        # Build list of texts that actually need translation
        texts_to_translate = []
        translate_map = []  # [(article_index, field)]
        for i, article in enumerate(articles):
            cached_en = cached.get(article.get("url", ""), {})
            title = (article.get("title") or "").strip()
            description = (article.get("description") or "").strip()

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
                if val:
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


async def get_news(page=1, page_size=20, lang="pt"):
    try:
        articles = await db_sqlite.get_news_page(page, page_size)

        for article in articles:
            article["_id"] = str(hash(article.get("url", "")))
            if lang == "en":
                if article.get("title_en"):
                    article["title"] = article["title_en"]
                if article.get("description_en"):
                    article["description"] = article["description_en"]

        return articles
    except Exception as e:
        logger.error("Error fetching news from DB: %s", e)
        return []


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
