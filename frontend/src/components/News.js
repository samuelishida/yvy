import React, { useEffect, useState, useCallback } from 'react';
import { useI18n } from '../i18n';
import { getCache, setCache } from '../utils/cache';
import './News.css';

const PAGE_SIZE = 20;

const normalizeArticles = (payload) => {
  if (Array.isArray(payload)) {
    return payload;
  }
  if (payload && Array.isArray(payload.articles)) {
    return payload.articles;
  }
  if (payload && Array.isArray(payload.data)) {
    return payload.data;
  }
  return [];
};

/**
 * Format an ISO-8601 date string as a human-readable relative or absolute date.
 * Returns e.g. "há 3 horas" (pt) / "3 hours ago" (en) for recent dates,
 * or "15 abr" / "Apr 15" for older ones.
 */
const formatDate = (isoString, lang) => {
  if (!isoString) return '';
  try {
    const date = new Date(isoString);
    const now = new Date();
    const diffMs = now - date;
    const diffMins = Math.floor(diffMs / 60000);
    const diffHours = Math.floor(diffMs / 3600000);
    const diffDays = Math.floor(diffMs / 86400000);

    if (lang === 'pt') {
      if (diffMins < 60) return diffMins <= 1 ? 'agora mesmo' : `há ${diffMins} min`;
      if (diffHours < 24) return diffHours === 1 ? 'há 1 hora' : `há ${diffHours} horas`;
      if (diffDays < 7) return diffDays === 1 ? 'ontem' : `há ${diffDays} dias`;
      return date.toLocaleDateString('pt-BR', { day: 'numeric', month: 'short' });
    } else {
      if (diffMins < 60) return diffMins <= 1 ? 'just now' : `${diffMins}m ago`;
      if (diffHours < 24) return diffHours === 1 ? '1 hour ago' : `${diffHours} hours ago`;
      if (diffDays < 7) return diffDays === 1 ? 'yesterday' : `${diffDays} days ago`;
      return date.toLocaleDateString('en-US', { day: 'numeric', month: 'short' });
    }
  } catch {
    return '';
  }
};

const News = () => {
  const { lang, t } = useI18n();
  const [articles, setArticles] = useState([]);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);
  const [hasMore, setHasMore] = useState(true);
  const [error, setError] = useState(null);
  const cacheKey = `news_${lang}`;

  useEffect(() => {
    const fetchNews = async () => {
      let cacheUsed = false;
      try {
        setError(null);

        // Try cache first for page 1 (stale-while-revalidate)
        if (page === 1) {
          const cached = getCache(cacheKey, 15);
          if (cached) {
            setArticles(cached);
            cacheUsed = true;
            // Still fetch in background to refresh silently
          }
        }

        if (!cacheUsed || page > 1) {
          setLoading(true);
        }

        const response = await fetch(`/api/news?page=${page}&lang=${lang}`);
        const payload = await response.json();
        const data = normalizeArticles(payload);

        if (!response.ok) {
          if (cacheUsed && page === 1) {
            // Keep cached data, silently ignore error
            return;
          }
          throw new Error(
            typeof payload?.error === 'string' && payload.error.trim()
              ? payload.error
              : t('news.errorLoading')
          );
        }

        if (page === 1) {
          setArticles(data);
          setCache(cacheKey, data);
        } else {
          setArticles((prevArticles) => [...prevArticles, ...data]);
        }

        if (data.length < PAGE_SIZE) {
          setHasMore(false);
        }
      } catch (err) {
        if (!cacheUsed) {
          setError(err?.message || t('news.errorLoading'));
          if (page === 1) setArticles([]);
          setHasMore(false);
        }
      } finally {
        setLoading(false);
      }
    };

    fetchNews();
  }, [page, lang, t, cacheKey]);

  const handleScroll = useCallback(() => {
    const navbarHeight = 62;
    const scrollBottom = window.innerHeight + document.documentElement.scrollTop;
    const pageHeight = document.documentElement.offsetHeight;
    if (scrollBottom + navbarHeight < pageHeight || loading || !hasMore) {
      return;
    }
    setPage((prevPage) => prevPage + 1);
  }, [loading, hasMore]);

  useEffect(() => {
    window.addEventListener('scroll', handleScroll);
    return () => window.removeEventListener('scroll', handleScroll);
  }, [handleScroll]);

  const handleLangChange = useCallback(() => {
    setArticles([]);
    setPage(1);
    setHasMore(true);
    setError(null);
  }, []);

  useEffect(() => {
    handleLangChange(lang);
  }, [lang, handleLangChange]);

  return (
    <div className="news-container">
      {error && !articles.length && <p className="news-error">{error}</p>}
      {articles.map((article) => {
        const title = lang === 'en' && article.title_en ? article.title_en : article.title;
        const description = lang === 'en' && article.description_en
          ? article.description_en
          : article.description;
        const sourceName = article.source_name || '';
        const dateStr = formatDate(article.publishedAt, lang);

        return (
          <div key={article.url} className="news-article">
            {article.urlToImage && (
              <div className="news-image-wrap">
                <img
                  className="news-image"
                  src={article.urlToImage}
                  alt={title}
                  loading="lazy"
                />
                <div className="news-image-fade" aria-hidden="true" />
              </div>
            )}
            <div className="news-content">
              {(sourceName || dateStr) && (
                <div className="news-meta">
                  {sourceName && (
                    <span className="news-source">{sourceName}</span>
                  )}
                  {sourceName && dateStr && (
                    <span className="news-dot" aria-hidden="true" />
                  )}
                  {dateStr && (
                    <span className="news-date">{dateStr}</span>
                  )}
                </div>
              )}
              <h3>{title}</h3>
              {description && <p>{description}</p>}
              <a
                href={article.url}
                className="news-btn"
                target="_blank"
                rel="noopener noreferrer"
              >
                {t('news.readMore')}
              </a>
            </div>
          </div>
        );
      })}
      {loading && (
        <p className="news-loading">
          <span className="news-spinner" aria-hidden="true" />
          {t('news.loadingMore')}
        </p>
      )}
    </div>
  );
};

export default News;
