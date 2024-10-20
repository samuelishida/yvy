// news-api.js

const NewsAPI = require('newsapi');
const News = require('../models/News');

const NEWS_API_KEY = process.env.NEWS_API_KEY;
const newsapi = new NewsAPI(NEWS_API_KEY);

// Função para verificar se há notícias recentes no banco de dados
async function hasRecentNews() {
  const oneDayAgo = new Date();
  oneDayAgo.setDate(oneDayAgo.getDate() - 1); // Ajuste o intervalo conforme necessário

  // Checa se há notícias publicadas nas últimas 24 horas (ou outro intervalo)
  const recentNews = await News.find({ publishedAt: { $gte: oneDayAgo } }).limit(1);

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
      q: 'environment OR sustainability OR ecology OR "climate change" OR biodiversity',
      language: 'pt',
      sortBy: 'publishedAt',
      pageSize: 100,
      sources: 'bbc-news, the-verge, national-geographic'
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
