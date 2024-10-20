// news-api.js

require('dotenv').config();
const NewsAPI = require('newsapi');
const News = require('../models/News');

const NEWS_API_KEY = process.env.NEWS_API_KEY;
const newsapi = new NewsAPI(NEWS_API_KEY);

async function fetchAndSaveNews() {
  try {
    const response = await newsapi.v2.topHeadlines({
      sources: 'globo,info-money', // Especifique as fontes desejadas
      // Outros parâmetros podem ser omitidos quando 'sources' é usado
    });

    const articles = response.articles;

    if (!articles || articles.length === 0) {
      console.log('Nenhum artigo encontrado para as fontes fornecidas.');
      return;
    }

    const bulkOps = articles.map((article) => ({
      updateOne: {
        filter: { url: article.url },
        update: { $set: article },
        upsert: true,
      },
    }));

    await News.bulkWrite(bulkOps);

    console.log(`${articles.length} artigos foram processados e salvos com sucesso.`);
  } catch (error) {
    console.error('Erro ao buscar ou salvar notícias:', error.message);
  }
}

module.exports = fetchAndSaveNews;
