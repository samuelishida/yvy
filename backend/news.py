import os
import logging
from datetime import datetime, timedelta
from newsapi import NewsApiClient
from newsapi.newsapi_exception import NewsAPIException
from pymongo import MongoClient
from dotenv import load_dotenv

load_dotenv()

logger = logging.getLogger(__name__)

NEWS_API_KEY = os.getenv("NEWS_API_KEY", "").strip()
newsapi = NewsApiClient(api_key=NEWS_API_KEY) if NEWS_API_KEY else None

if newsapi:
    logger.info("NewsAPI client initialized.")
else:
    logger.warning("NewsAPI not configured - NEWS_API_KEY missing.")


def get_mongo_client():
    from urllib.parse import quote_plus
    
    explicit_uri = os.getenv("MONGO_URI", "").strip()
    if explicit_uri:
        return MongoClient(explicit_uri)
    
    database = os.getenv("MONGO_DATABASE", "terrabrasilis_data")
    host = os.getenv("MONGO_HOST", "mongo")
    port = os.getenv("MONGO_PORT", "27017")
    app_username = os.getenv("MONGO_APP_USERNAME", "").strip()
    app_password = os.getenv("MONGO_APP_PASSWORD", "").strip()
    root_username = os.getenv("MONGO_ROOT_USERNAME", "").strip()
    root_password = os.getenv("MONGO_ROOT_PASSWORD", "").strip()
    
    if app_username and app_password:
        uri = f"mongodb://{quote_plus(app_username)}:{quote_plus(app_password)}@{host}:{port}/{database}?authSource={database}"
        return MongoClient(uri, authMechanism='SCRAM-SHA-1')
    
    if root_username and root_password:
        uri = f"mongodb://{quote_plus(root_username)}:{quote_plus(root_password)}@{host}:{port}/{database}?authSource=admin"
        return MongoClient(uri, authMechanism='SCRAM-SHA-1')
    
    return MongoClient(f"mongodb://{host}:{port}/{database}")


def has_recent_news(db):
    fifteen_minutes_ago = datetime.now() - timedelta(minutes=15)
    recent_news = db.news.find({"publishedAt": {"$gte": fifteen_minutes_ago}}).limit(1)
    return recent_news.count() > 0


def extract_title_from_url(url):
    import re
    from urllib.parse import unquote
    match = re.search(r'(?:https?://)?(?:www\.)?[\w.-]+\.\w{2,}(?:/[\w%-]*/)([\w%-]+)(?:\.\w+)?$', url)
    if match and match.group(1):
        decoded = unquote(match.group(1))
        return decoded.replace('-', ' ').title()
    return None


def fetch_and_save_news():
    if not newsapi:
        logger.warning("NEWS_API_KEY not configured. Skipping news fetch.")
        return []
    
    client = get_mongo_client()
    db = client[os.getenv("MONGO_DATABASE", "terrabrasilis_data")]
    
    try:
        if has_recent_news(db):
            logger.info("Recent news already available. Skipping fetch.")
            return list(db.news.find().sort("publishedAt", -1).limit(20))
        
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
            
            db.news.update_one(
                {"url": article['url']},
                {"$set": article},
                upsert=True
            )
        
        logger.info(f"Processed {len(articles)} articles.")
        return list(db.news.find().sort("publishedAt", -1).limit(20))
    except NewsAPIException as e:
        logger.error(f"NewsAPI error: {e}")
        return list(db.news.find().sort("publishedAt", -1).limit(20))
    except Exception as e:
        logger.error(f"Error fetching/saving news: {e}")
        return []
    finally:
        client.close()


def get_news(page=1, page_size=20):
    client = get_mongo_client()
    db = client[os.getenv("MONGO_DATABASE", "terrabrasilis_data")]
    
    try:
        skip = (page - 1) * page_size
        articles = list(db.news.find().sort("publishedAt", -1).skip(skip).limit(page_size))
        
        for article in articles:
            article['_id'] = str(article['_id'])
        
        return articles
    except Exception as e:
        logger.error(f"Error fetching news from DB: {e}")
        return []
    finally:
        client.close()
