// news-api.js

const NewsAPI = require('newsapi');
const News = require('../models/News');

const NEWS_API_KEY = process.env.NEWS_API_KEY;
const newsapi = new NewsAPI(NEWS_API_KEY);

// Função para verificar se há notícias recentes no banco de dados
async function hasRecentNews() {
  const oneHourAgo = new Date();
  oneHourAgo.setHours(oneHourAgo.getHours() - 1); // Ajusta o intervalo para 1 hora atrás

  // Checa se há notícias publicadas na última 1 hora
  const recentNews = await News.find({ publishedAt: { $gte: oneHourAgo } }).limit(1);

  return recentNews.length > 0;
}

async function fetchAndSaveNews() {
  try {
    // Primeiro, checa se já há notícias recentes no banco de dados
    const hasNews = await hasRecentNews();

    if (hasNews) {
      console.log('Notícias recentes já estão disponíveis no banco de dados. Nenhuma nova requisição será feita.');
      return;
    }

    // Se não houver notícias recentes, faz a requisição à API de notícias
    const response = await newsapi.v2.everything({
      q: 'environment OR sustainability OR ecology OR biodiversity OR meio ambiente OR sustentabilidade OR ecologia OR biodiversidade',
      language: 'pt',
      sortBy: 'publishedAt',
      pageSize: 50,
      sources: 'national-geographic, new-scientist, nature, scientific-american, reuters, bbc-news'
    });    

    const articles = response.articles;

    if (!articles || articles.length === 0) {
      console.log('Nenhum artigo encontrado para os termos fornecidos.');
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
