import React, { useEffect, useState, useRef, useMemo, memo } from 'react';
import { useI18n } from '../i18n';
import { getCache, setCacheSync } from '../utils/cache';
import './News.css';

const PAGE_SIZE = 5;

/**
 * Canonical article URL for dedupe: strip fragment + trailing slashes so the
 * same story served with/without a trailing "/" doesn't show up twice.
 * Mirrors app/db.lua canonical_url().
 */
const canonUrl = (u) => {
  if (!u) return u;
  const base = u.split('#')[0];
  return base.length > 1 ? base.replace(/\/+$/, '') : base;
};

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

/** Dedupe an article list by canonical URL (first occurrence wins). */
const dedupeByCanonUrl = (articles) => {
  const seen = new Set();
  const out = [];
  for (const a of articles) {
    const c = canonUrl(a.url);
    if (c && !seen.has(c)) {
      seen.add(c);
      out.push(a);
    }
  }
  return out;
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

const NewsArticle = memo(function NewsArticle({ article, lang, readMoreText }) {
  const title = lang === 'en' && article.title_en ? article.title_en : article.title;
  const description = lang === 'en' && article.description_en ? article.description_en : article.description;
  const sourceName = article.source_name || '';
  const dateStr = formatDate(article.publishedAt, lang);

  return (
    <div className="news-article">
      {article.urlToImage && (
        <div className="news-image-wrap">
          <img
            className="news-image"
            src={article.urlToImage}
            alt={title}
            loading="lazy"
            decoding="async"
            width="320"
            height="180"
          />
        </div>
      )}
      <div className="news-content">
        {(sourceName || dateStr) && (
          <div className="news-meta">
            {sourceName && <span className="news-source">{sourceName}</span>}
            {sourceName && dateStr && <span className="news-dot" aria-hidden="true" />}
            {dateStr && <span className="news-date">{dateStr}</span>}
          </div>
        )}
        <h3>{title}</h3>
        {description && <p>{description}</p>}
        <a href={article.url} className="news-btn" target="_blank" rel="noopener noreferrer">
          {readMoreText}
        </a>
      </div>
    </div>
  );
});

const News = () => {
  const { lang, t } = useI18n();
  const [articles, setArticles] = useState([]);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);
  const [hasMore, setHasMore] = useState(true);
  const [error, setError] = useState(null);
  const [stale, setStale] = useState(false);  // true when showing cached data after a failed refresh
  const cacheKey = `news_${lang}`;
  const fetchingRef = useRef(false);
  const sentinelRef = useRef(null);

  useEffect(() => {
    const ac = new AbortController();
    let cancelled = false;

    const fetchNews = async () => {
      if (fetchingRef.current) return;
      fetchingRef.current = true;
      let cacheUsed = false;
      try {
        setError(null);
        setStale(false);

        if (page === 1) {
          // Short TTL (2 min): news is a live feed — a long cache made
          // navigating back to /news show a stale set ("set antigo") even
          // though new articles had been ingested. 2 min is just a paint
          // optimization; the fetch below always refreshes on mount.
          const cached = getCache(cacheKey, 2);
          if (cached) {
            setArticles(cached);
            cacheUsed = true;
          }
        }

        // Always show loading — even with cached data the user should know
        // a refresh is happening. Without this, a failed fetch on a cached
        // page silently showed stale data forever with no visual feedback.
        setLoading(true);

        const response = await fetch(`/api/news?page=${page}&page_size=${PAGE_SIZE}&lang=${lang}`, { signal: ac.signal });
        if (cancelled) return;
        const payload = await response.json();
        if (cancelled) return;
        const data = normalizeArticles(payload);

        if (!response.ok) {
          // Never silently keep stale data. If we have cached articles,
          // mark them as stale so the user knows the fetch failed.
          if (cacheUsed && page === 1) {
            setStale(true);
            setHasMore(false);
            return;
          }
          throw new Error(
            typeof payload?.error === 'string' && payload.error.trim()
              ? payload.error
              : t('news.errorLoading')
          );
        }

        if (page === 1) {
          setArticles(dedupeByCanonUrl(data));
          setCacheSync(cacheKey, data);  // sync write — small payload, no need to defer
        } else {
          setArticles((prevArticles) => {
            const seen = new Set(prevArticles.map(a => canonUrl(a.url)));
            return [...prevArticles, ...data.filter(a => !seen.has(canonUrl(a.url)))];
          });
        }

        if (data.length < PAGE_SIZE) {
          setHasMore(false);
        }
      } catch (err) {
        if (err.name === 'AbortError' || cancelled) return;
        // If we have cached data, mark it stale instead of replacing with
        // an empty error state — the user can still read what's there.
        if (cacheUsed && page === 1) {
          setStale(true);
          setHasMore(false);
        } else {
          setError(err?.message || t('news.errorLoading'));
          if (page === 1) setArticles([]);
          setHasMore(false);
        }
      } finally {
        if (!cancelled) setLoading(false);
        fetchingRef.current = false;
      }
    };

    fetchNews();

    return () => {
      cancelled = true;
      ac.abort();
      fetchingRef.current = false;
    };
  }, [page, lang, t, cacheKey]);

  useEffect(() => {
    const node = sentinelRef.current;
    if (!node || !hasMore || loading) return;
    const observer = new IntersectionObserver((entries) => {
      if (entries[0].isIntersecting && hasMore) {
        observer.disconnect();
        setPage((prevPage) => prevPage + 1);
      }
    }, { rootMargin: '200px', threshold: 0 });
    observer.observe(node);
    return () => observer.disconnect();
  }, [hasMore, loading]);

  useEffect(() => {
    fetchingRef.current = false;
    setArticles([]);
    setPage(1);
    setHasMore(true);
    setError(null);
  }, [lang]);

  const readMoreText = useMemo(() => t('news.readMore'), [t]);

  return (
    <div className="news-container">
      {stale && articles.length > 0 && (
        <p className="news-stale-banner">
          ⚠ {lang === 'pt' ? 'Mostrando dados em cache — não foi possível atualizar.' : 'Showing cached data — could not refresh.'}
        </p>
      )}
      {error && !articles.length && <p className="news-error">{error}</p>}
      {articles.map((article) => (
        <NewsArticle key={article.url} article={article} lang={lang} readMoreText={readMoreText} />
      ))}
      {loading && (
        <p className="news-loading">
          <span className="news-spinner" aria-hidden="true" />
          {t('news.loadingMore')}
        </p>
      )}
      {hasMore && !error && <div ref={sentinelRef} className="news-sentinel" aria-hidden="true" />}
      {!hasMore && !error && articles.length > 0 && (
        <p className="news-loading">{t('news.noMore')}</p>
      )}
    </div>
  );
};

export default News;
