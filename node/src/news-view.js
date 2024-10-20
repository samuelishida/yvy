// News.js

import React, { useEffect, useState } from 'react';
import './News.css'; // Certifique-se de que o arquivo CSS está importado
import Carousel from 'react-bootstrap/Carousel';

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
      <Carousel>
        {articles.map((article, index) => (
          <Carousel.Item key={index}>
            {article.urlToImage && (
              <img
                className="d-block w-100 news-carousel-image"
                src={article.urlToImage}
                alt={article.title}
              />
            )}
            <Carousel.Caption className="news-carousel-caption">
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
            </Carousel.Caption>
          </Carousel.Item>
        ))}
      </Carousel>
    </div>
  );
};

export default News;
