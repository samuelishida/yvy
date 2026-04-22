import os
import logging
from datetime import datetime, timedelta, timezone

import httpx

logger = logging.getLogger(__name__)

NEWS_API_KEY = os.getenv("NEWS_API_KEY", "").strip()
NEWS_API_BASE_URL = "https://newsapi.org/v2"


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


async def get_news(db, page=1, page_size=20):
    try:
        skip = (page - 1) * page_size
        cursor = db.news.find().sort("publishedAt", -1).skip(skip).limit(page_size)
        articles = await cursor.to_list(length=page_size)

        for article in articles:
            article["_id"] = str(article["_id"])

        return articles
    except Exception as e:
        logger.error("Error fetching news from DB: %s", e)
        return []


def extract_title_from_url(url):
    if not url:
        return None
    parts = url.rstrip("/").split("/")
    last_part = parts[-1] if parts else ""
    return last_part.replace("-", " ").strip() if last_part else None