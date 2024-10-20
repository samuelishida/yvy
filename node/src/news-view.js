import React, { useEffect, useState } from 'react';
import './news.css'; // Certifique-se de que o arquivo CSS está importado

const News = () => {
  const [articles, setArticles] = useState([]);
  const [page, setPage] = useState(1); // Para controlar a paginação
  const [loading, setLoading] = useState(false); // Para controlar o estado de carregamento

  useEffect(() => {
    const fetchNews = async () => {
      try {
        setLoading(true); // Define o estado de carregamento como true
        const response = await fetch(`/api/news?page=${page}`);
        const data = await response.json();
        setArticles((prevArticles) => [...prevArticles, ...data]); // Adiciona mais artigos
        setLoading(false); // Define o estado de carregamento como false
      } catch (error) {
        console.error('Erro ao carregar notícias:', error);
        setLoading(false); // Define o estado de carregamento como false
      }
    };

    fetchNews();
  }, [page]);

  // Função para detectar o scroll
  const handleScroll = () => {
    if (window.innerHeight + document.documentElement.scrollTop !== document.documentElement.offsetHeight || loading) {
      return;
    }
    // Aumenta a página para carregar mais artigos
    setPage((prevPage) => prevPage + 1);
  };

  useEffect(() => {
    window.addEventListener('scroll', handleScroll);
    return () => window.removeEventListener('scroll', handleScroll); // Cleanup do event listener
  }, [loading]);

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
