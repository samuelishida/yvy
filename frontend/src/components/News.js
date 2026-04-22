import React, { useEffect, useState, useCallback } from 'react';
import './News.css';

const PAGE_SIZE = 20;

const News = () => {
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
        const response = await fetch(`/api/news?page=${page}`);
        const data = await response.json();

        if (page === 1) {
          setArticles(data);
        } else {
          setArticles((prevArticles) => [...prevArticles, ...data]);
        }

        // If we got fewer articles than the expected page size, we've reached the end
        if (data.length < PAGE_SIZE) {
          setHasMore(false);
        }

        setLoading(false);
      } catch (err) {
        setError('Erro ao carregar notícias. Tente novamente mais tarde.');
        setLoading(false);
        setHasMore(false);
      }
    };

    fetchNews();
  }, [page]);

  const handleScroll = useCallback(() => {
    if (window.innerHeight + document.documentElement.scrollTop !== document.documentElement.offsetHeight || loading || !hasMore) {
      return;
    }
    setPage((prevPage) => prevPage + 1);
  }, [loading, hasMore]);

  useEffect(() => {
    window.addEventListener('scroll', handleScroll);
    return () => window.removeEventListener('scroll', handleScroll);
  }, [handleScroll]);

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
            <h3>{article.title}</h3>
            <p>{article.description}</p>
            <a
              href={article.url}
              className="news-btn"
              target="_blank"
              rel="noopener noreferrer"
            >
              Ler mais
            </a>
          </div>
        </div>
      ))}
      {loading && <p className="news-loading">Carregando mais notícias...</p>}
    </div>
  );
};

export default News;
