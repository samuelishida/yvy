import os
import logging
from datetime import datetime, timedelta, timezone
from newsapi import NewsApiClient
from newsapi.newsapi_exception import NewsAPIException

logger = logging.getLogger(__name__)

NEWS_API_KEY = os.getenv("NEWS_API_KEY", "").strip()
newsapi = NewsApiClient(api_key=NEWS_API_KEY) if NEWS_API_KEY else None

if newsapi:
    logger.info("NewsAPI client initialized.")
else:
    logger.warning("NewsAPI not configured - NEWS_API_KEY missing.")


def has_recent_news(mongo):
    fifteen_minutes_ago = datetime.now(timezone.utc) - timedelta(minutes=15)
    recent_count = mongo.db.news.count_documents({"publishedAt": {"$gte": fifteen_minutes_ago}})
    return recent_count > 0


def fetch_and_save_news(mongo):
    if not newsapi:
        logger.warning("NEWS_API_KEY not configured. Skipping news fetch.")
        return []
    
    try:
        if has_recent_news(mongo):
            logger.info("Recent news already available. Skipping fetch.")
            return list(mongo.db.news.find().sort("publishedAt", -1).limit(20))
        
        logger.info("Fetching news from NewsAPI...")
        response = newsapi.get_everything(
            q='environment OR sustainability OR ecology OR climate OR "meio ambiente" OR sustentabilidade OR ecologia OR biodiversidade',
            language='pt',
            sort_by='publishedAt',
            page_size=10,
        )
        
        articles = response.get('articles', [])
        if not articles:
            logger.info("No articles found.")
            return []
        
        for article in articles:
            if not article.get('title'):
                extracted = extract_title_from_url(article.get('url', ''))
                article['title'] = extracted or (article.get('description', '')[:50] + '...' if article.get('description') else '#')
            
            mongo.db.news.update_one(
                {"url": article['url']},
                {"$set": article},
                upsert=True
            )
        
        logger.info(f"Processed {len(articles)} articles.")
        return list(mongo.db.news.find().sort("publishedAt", -1).limit(20))
    except NewsAPIException as e:
        logger.error(f"NewsAPI error: {e}")
        return list(mongo.db.news.find().sort("publishedAt", -1).limit(20))
    except Exception as e:
        logger.error(f"Error fetching/saving news: {e}")
        return []


def get_news(mongo, page=1, page_size=20):
    try:
        skip = (page - 1) * page_size
        articles = list(mongo.db.news.find().sort("publishedAt", -1).skip(skip).limit(page_size))
        
        for article in articles:
            article['_id'] = str(article['_id'])
        
        return articles
    except Exception as e:
        logger.error(f"Error fetching news from DB: {e}")
        return []
