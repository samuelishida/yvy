import React, { useEffect, useState, useCallback } from 'react';
import { useI18n } from '../i18n';
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

const News = () => {
  const { lang, t } = useI18n();
  const [articles, setArticles] = useState([]);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);
  const [hasMore, setHasMore] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    const fetchNews = async () => {
      try {
        setLoading(true);
        setError(null);
        const response = await fetch(`/api/news?page=${page}&lang=${lang}`);
        const payload = await response.json();
        const data = normalizeArticles(payload);

        if (!response.ok) {
          throw new Error(
            typeof payload?.error === 'string' && payload.error.trim()
              ? payload.error
              : t('news.errorLoading')
          );
        }

        if (page === 1) {
          setArticles(data);
        } else {
          setArticles((prevArticles) => [...prevArticles, ...data]);
        }

        if (data.length < PAGE_SIZE) {
          setHasMore(false);
        }

        setLoading(false);
      } catch (err) {
        setError(err?.message || t('news.errorLoading'));
        setArticles((prevArticles) => (page === 1 ? [] : prevArticles));
        setLoading(false);
        setHasMore(false);
      }
    };

    fetchNews();
  }, [page, lang, t]);

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
  }, []);

  useEffect(() => {
    handleLangChange(lang);
  }, [lang, handleLangChange]);

  return (
    <div className="news-container">
      {error && <p className="news-error">{error}</p>}
      {articles.map((article) => (
        <div key={article.url} className="news-article">
          {article.urlToImage && (
            <img
              className="news-image"
              src={article.urlToImage}
              alt={article.title}
            />
          )}
          <div className="news-content">
            <h3>{lang === 'en' && article.title_en ? article.title_en : article.title}</h3>
            <p>{lang === 'en' && article.description_en ? article.description_en : article.description}</p>
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
      ))}
      {loading && <p className="news-loading">{t('news.loadingMore')}</p>}
    </div>
  );
};

export default News;