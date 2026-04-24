import os
import logging
from datetime import datetime, timedelta, timezone

import httpx

logger = logging.getLogger(__name__)

NEWS_API_KEY = os.getenv("NEWS_API_KEY", "").strip()
NEWS_API_BASE_URL = "https://newsapi.org/v2"
MYMEMORY_API_URL = "https://api.mymemory.translated.net/get"


async def has_recent_news(db):
    fifteen_minutes_ago = datetime.now(timezone.utc) - timedelta(minutes=15)
    recent_count = await db.news.count_documents({"publishedAt": {"$gte": fifteen_minutes_ago}})
    return recent_count > 0


async def fetch_and_save_news(db):
    if not NEWS_API_KEY:
        logger.warning("NEWS_API_KEY not configured. Skipping news fetch.")
        return []

    try:
        if await has_recent_news(db):
            logger.info("Recent news already available. Skipping fetch.")
            cursor = db.news.find().sort("publishedAt", -1).limit(20)
            return await cursor.to_list(length=20)

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

            await db.news.update_one(
                {"url": article["url"]},
                {"$set": article},
                upsert=True,
            )

        logger.info("Processed %d articles.", len(articles))
        cursor = db.news.find().sort("publishedAt", -1).limit(20)
        return await cursor.to_list(length=20)
    except httpx.HTTPStatusError as e:
        logger.error("NewsAPI HTTP error: %s", e)
        cursor = db.news.find().sort("publishedAt", -1).limit(20)
        return await cursor.to_list(length=20)
    except Exception as e:
        logger.error("Error fetching/saving news: %s", e)
        return []


async def get_news(db, page=1, page_size=20, lang="pt"):
    try:
        skip = (page - 1) * page_size
        cursor = db.news.find().sort("publishedAt", -1).skip(skip).limit(page_size)
        articles = await cursor.to_list(length=page_size)

        for article in articles:
            article["_id"] = str(article["_id"])

        if lang == "en":
            articles = await translate_articles(db, articles)

        return articles
    except Exception as e:
        logger.error("Error fetching news from DB: %s", e)
        return []


async def translate_articles(db, articles):
    texts_to_translate = []
    for article in articles:
        title = (article.get("title") or "").strip()
        desc = (article.get("description") or "").strip()
        texts_to_translate.append(title)
        texts_to_translate.append(desc)

    translations = await batch_translate(db, texts_to_translate, "pt", "en")

    for i, article in enumerate(articles):
        t_title = translations.get(i * 2, "")
        t_desc = translations.get(i * 2 + 1, "")
        if t_title:
            article["title_en"] = t_title
        if t_desc:
            article["description_en"] = t_desc

    return articles


async def batch_translate(db, texts, source_lang, target_lang):
    results = {}
    untranslated_indices = []

    for i, text in enumerate(texts):
        if not text:
            results[i] = ""
            continue

        cached = await db.news_translations.find_one({
            "source_lang": source_lang,
            "target_lang": target_lang,
            "source_text_hash": _hash_text(text),
        })

        if cached:
            results[i] = cached["translated_text"]
        else:
            untranslated_indices.append(i)

    if untranslated_indices:
        async with httpx.AsyncClient(timeout=15) as client:
            for i in untranslated_indices:
                text = texts[i]
                try:
                    resp = await client.get(MYMEMORY_API_URL, params={
                        "q": text[:500],
                        "langpair": f"{source_lang}|{target_lang}",
                    })
                    data = resp.json()
                    translated = data.get("responseData", {}).get("translatedText", "")
                    if translated and translated.lower() != text.lower():
                        results[i] = translated
                        await db.news_translations.update_one(
                            {"source_text_hash": _hash_text(text), "source_lang": source_lang, "target_lang": target_lang},
                            {"$set": {
                                "source_text": text,
                                "translated_text": translated,
                                "source_lang": source_lang,
                                "target_lang": target_lang,
                                "source_text_hash": _hash_text(text),
                                "created_at": datetime.now(timezone.utc),
                            }},
                            upsert=True,
                        )
                    else:
                        results[i] = text
                except Exception as e:
                    logger.warning("Translation failed for text %d: %s", i, e)
                    results[i] = text

    return results


def _hash_text(text):
    import hashlib
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def extract_title_from_url(url):
    if not url:
        return None
    parts = url.rstrip("/").split("/")
    last_part = parts[-1] if parts else ""
    return last_part.replace("-", " ").strip() if last_part else None