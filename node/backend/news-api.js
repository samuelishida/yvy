const NewsAPI = require('newsapi');
const News = require('../models/news');

const NEWS_API_KEY = process.env.NEWS_API_KEY;
const newsapi = new NewsAPI(NEWS_API_KEY);

// Função para verificar se há notícias recentes no banco de dados
async function hasRecentNews() {
  const fifteenMinutesAgo = new Date();
  fifteenMinutesAgo.setMinutes(fifteenMinutesAgo.getMinutes() - 15); // Ajusta o intervalo para 15 minutos atrás

  // Checa se há notícias publicadas nos últimos 15 minutos
  const recentNews = await News.find({ publishedAt: { $gte: fifteenMinutesAgo } }).limit(1);

  return recentNews.length > 0;
}

// Função para extrair título do URL usando regex e decodificação de caracteres
function extractTitleFromUrl(url) {
  // Regex para capturar a última parte do caminho da URL (antes de ".html", ".shtml", ou números)
  const regex = /(?:https?:\/\/)?(?:www\.)?[\w.-]+\.\w{2,}(?:\/[\w%-]+)*\/([\w%-]+)(?:\.\w+)?$/;
  const match = url.match(regex);
  if (match && match[1]) {
    // Decodificar caracteres especiais na URL (ex: %C3%AD -> í)
    const decodedTitle = decodeURIComponent(match[1]);
    // Substituir hífens por espaços e capitalizar a primeira letra de cada palavra
    return decodedTitle.replace(/-/g, ' ').replace(/\b\w/g, (char) => char.toUpperCase());
  }
  return null;
}


async function fetchAndSaveNews() {
  try {
    const hasNews = await hasRecentNews();

    if (hasNews) {
      console.log('Notícias recentes já estão disponíveis no banco de dados. Nenhuma nova requisição será feita.');
      return;
    }

    const response = await newsapi.v2.everything({
      q: 'environment OR sustainability OR ecology OR climate OR "meio ambiente" OR sustentabilidade OR ecologia OR biodiversidade',
      language: 'pt', // ou 'en'
      sortBy: 'publishedAt',
      pageSize: 1,
    });

    const articles = response.articles;

    if (!articles || articles.length === 0) {
      console.log('Nenhum artigo encontrado para os termos fornecidos.');
      return;
    }

    const bulkOps = articles.map((article) => {
      // Debug: Logar o artigo que está sendo processado
      console.log('Artigo processado:', article);

      // Se o título estiver ausente, tentar extrair do URL
      if (!article.title) {
        let extractedTitle = extractTitleFromUrl(article.url);

        // Se não conseguiu extrair do URL, usar a descrição ou definir como '#'
        if (!extractedTitle && article.description) {
          extractedTitle = article.description.substring(0, 50) + '...'; // Usar parte da descrição como título
        }

        article.title = extractedTitle || "#"; // Se não for possível extrair, usar '#'
      }

      return {
        updateOne: {
          filter: { url: article.url },
          update: { $set: article },
          upsert: true,
        },
      };
    });

    // Debug: Logar o array de operações de bulk
    console.log('Operações de bulk:', bulkOps);

    await News.bulkWrite(bulkOps);

    console.log(`${articles.length} artigos foram processados e salvos com sucesso.`);
  } catch (error) {
    console.error('Erro ao buscar ou salvar notícias:', error.message);
  }
}

module.exports = fetchAndSaveNews;
