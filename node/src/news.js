// News.js

import React, { useEffect, useState } from 'react';
import './news.css'; // Certifique-se de que o arquivo CSS está importado

const News = () => {
  const [articles, setArticles] = useState([]);

  useEffect(() => {
    const fetchNews = async () => {
      try {
        const response = await fetch('/api/news');
        const data = await response.json();
        setArticles(data);
      } catch (error) {
        console.error('Erro ao carregar notícias:', error);
      }
    };

    fetchNews();
  }, []);

  return (
    <div className="news-container">
      <div className="jumbotron text-center">
        <h1 className="display-4">Notícias Ambientais</h1>
        <p className="lead">Confira as principais notícias sobre meio ambiente.</p>
        <div className="d-flex flex-wrap justify-content-center mt-4">
          <button className="btn btn-custom btn-lg mb-3 mx-2" onClick={() => window.location.href = 'https://g1.globo.com/natureza/'}>Ver Notícias do G1 Meio Ambiente</button>
          <button className="btn btn-custom btn-lg mb-3 mx-2" onClick={() => window.location.href = 'https://climainfo.org.br/'}>Ver Notícias do ClimaInfo</button>
        </div>
      </div>

      <div className="news-scroll">
        {articles.map((article, index) => (
          <div key={index} className="news-block">
            {article.urlToImage && (
              <img src={article.urlToImage} alt={article.title} className="news-image" />
            )}
            <div className="news-content">
              <h2 className="news-heading">{article.title}</h2>
              <p className="news-description">{article.description}</p>
              <a href={article.url} target="_blank" rel="noopener noreferrer" className="news-link">
                Ler mais
              </a>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};

export default News;
