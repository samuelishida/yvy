import React, { useEffect, useState, useCallback } from 'react';
import './News.css';

const News = () => {
  const [articles, setArticles] = useState([]);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const fetchNews = async () => {
      try {
        setLoading(true);
        const response = await fetch(`/api/news?page=${page}`);
        const data = await response.json();
        
        if (page === 1) {
          setArticles(data);
        } else {
          setArticles((prevArticles) => [...data, ...prevArticles]);
        }

        setLoading(false);
      } catch (error) {
        console.error('Erro ao carregar notícias:', error);
        setLoading(false);
      }
    };

    fetchNews();
  }, [page]);

  const handleScroll = useCallback(() => {
    if (window.innerHeight + document.documentElement.scrollTop !== document.documentElement.offsetHeight || loading) {
      return;
    }
    setPage((prevPage) => prevPage + 1);
  }, [loading]);

  useEffect(() => {
    window.addEventListener('scroll', handleScroll);
    return () => window.removeEventListener('scroll', handleScroll);
  }, [handleScroll]);

  return (
    <div className="news-container">
      {articles.map((article, index) => (
        <div key={index} className="news-article">
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
