"""News module using SQLite instead of MongoDB."""
import os
import logging
from datetime import datetime, timedelta, timezone

import httpx

import db_sqlite

logger = logging.getLogger(__name__)

NEWS_API_KEY = os.getenv("NEWS_API_KEY", "").strip()
NEWS_API_BASE_URL = "https://newsapi.org/v2"
MYMEMORY_API_URL = "https://api.mymemory.translated.net/get"


async def has_recent_news():
    return await db_sqlite.has_recent_news(minutes=15)


async def fetch_and_save_news():
    if not NEWS_API_KEY:
        logger.warning("NEWS_API_KEY not configured. Skipping news fetch.")
        return []

    try:
        if await has_recent_news():
            logger.info("Recent news already available. Skipping fetch.")
            return await db_sqlite.get_news_page(page=1, page_size=20)

        logger.info("Fetching news from NewsAPI...")
        async with httpx.AsyncClient(timeout=30) as client:
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

        for article in articles:
            if not article.get("title"):
                extracted = extract_title_from_url(article.get("url", ""))
                article["title"] = extracted or (article.get("description", "")[:50] + "..." if article.get("description") else "#")

            await db_sqlite.upsert_news(article)

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
            articles = await translate_articles(articles)

        return articles
    except Exception as e:
        logger.error("Error fetching news from DB: %s", e)
        return []


async def translate_articles(articles):
    texts_to_translate = []
    for article in articles:
        title = (article.get("title") or "").strip()
        desc = (article.get("description") or "").strip()
        texts_to_translate.append(title)
        texts_to_translate.append(desc)

    translations = await batch_translate(texts_to_translate, "pt", "en")

    for i, article in enumerate(articles):
        t_title = translations.get(i * 2, "")
        t_desc = translations.get(i * 2 + 1, "")
        if t_title:
            article["title_en"] = t_title
        if t_desc:
            article["description_en"] = t_desc

    return articles


async def batch_translate(texts, source_lang, target_lang):
    results = {}
    untranslated_indices = []

    for i, text in enumerate(texts):
        if not text:
            results[i] = ""
            continue
        untranslated_indices.append(i)

    if not untranslated_indices:
        return results

    semaphore = asyncio.Semaphore(5)

    async def translate_one(idx):
        text = texts[idx]
        async with semaphore:
            try:
                async with httpx.AsyncClient(timeout=10) as client:
                    resp = await client.get(
                        MYMEMORY_API_URL,
                        params={
                            "q": text[:500],
                            "langpair": f"{source_lang}|{target_lang}",
                        },
                    )
                    data = resp.json()
                    translation = data.get("responseData", {}).get("translatedText", "")
                    if translation and translation.lower() != text.lower():
                        results[idx] = translation
                        return
            except Exception:
                pass
            results[idx] = ""

    await asyncio.gather(*(translate_one(idx) for idx in untranslated_indices))
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
