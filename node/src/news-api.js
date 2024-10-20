// news-api.js

require('dotenv').config();
const NewsAPI = require('newsapi');
const News = require('./models/News');

const NEWS_API_KEY = process.env.NEWS_API_KEY;
const newsapi = new NewsAPI(NEWS_API_KEY);

async function fetchAndSaveNews() {
  try {
    const response = await newsapi.v2.topHeadlines({
      country: 'br',
      q: 'meio ambiente OR sustentabilidade OR ecologia',
      // Se desejar, adicione mais termos relacionados
    });

    const articles = response.articles;

    if (!articles || articles.length === 0) {
      console.log('Nenhum artigo encontrado para os termos de busca fornecidos.');
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

    console.log(`${articles.length} artigos sobre meio ambiente foram processados e salvos com sucesso.`);
  } catch (error) {
    console.error('Erro ao buscar ou salvar notícias:', error.message);
  }
}

module.exports = fetchAndSaveNews;
