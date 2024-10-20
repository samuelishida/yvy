// News.js

import React, { useEffect, useState } from 'react';

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
    <div>
      <h1>Últimas Notícias sobre Meio Ambiente</h1>
      {articles.map((article, index) => (
        <div key={index} style={{ marginBottom: '20px' }}>
          <h2>{article.title}</h2>
          <p>{article.description}</p>
          <a href={article.url} target="_blank" rel="noopener noreferrer">
            Ler mais
          </a>
        </div>
      ))}
    </div>
  );
};

export default News;
