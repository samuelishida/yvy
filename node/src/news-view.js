import React, { useEffect, useState, useCallback } from 'react';
import './news.css';
import './yvy.css';

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
        
        // Atualizar o estado substituindo os artigos anteriores, garantindo que os mais recentes venham no topo
        if (page === 1) {
          setArticles(data);  // Para a primeira página, substituir tudo
        } else {
          setArticles((prevArticles) => [...data, ...prevArticles]);  // Para outras páginas, adicionar no topo
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
              className="btn btn-primary"
              target="_blank"
              rel="noopener noreferrer"
            >
              Ler mais
            </a>
          </div>
        </div>
      ))}
      {loading && <p>Carregando mais notícias...</p>}
    </div>
  );
};

export default News;
