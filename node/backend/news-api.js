const NewsAPI = require('newsapi');
const News = require('../models/News');

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
  const regex = /(?:https?:\/\/)?(?:www\.)?[\w.-]+\.\w{2,}(?:\/[\w%-]+)*\/([\w%-]+)(?:\.\w+)?$/;
  const match = url.match(regex);
  if (match && match[1]) {
    const decodedTitle = decodeURIComponent(match[1]);
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
      pageSize: 3,
    });

    const articles = response.articles;

    if (!articles || articles.length === 0) {
      console.log('Nenhum artigo encontrado para os termos fornecidos.');
      return;
    }

    const bulkOps = await Promise.all(articles.map(async (article) => {
      // Verificar se o artigo já existe no banco de dados
      const existingArticle = await News.findOne({ url: article.url });

      // Se o título estiver ausente, tentar extrair do URL
      if (!article.title) {
        let extractedTitle = extractTitleFromUrl(article.url);
        if (!extractedTitle && article.description) {
          extractedTitle = article.description.substring(0, 50) + '...';
        }
        article.title = extractedTitle || "#";
      }

      // Se o artigo já existir e `publishedAt` for o mesmo, não fazer nada
      if (existingArticle && existingArticle.publishedAt.getTime() === new Date(article.publishedAt).getTime()) {
        console.log(`Artigo já existente e atualizado: ${article.title}`);
        return null; // Não precisa ser atualizado
      }

      // Se for um artigo novo ou se tiver atualização, aplicar o updateOne com upsert
      return {
        updateOne: {
          filter: { url: article.url },
          update: { $set: article },
          upsert: true,
        },
      };
    }));

    // Remover operações `null` (quando não há necessidade de atualização)
    const validOps = bulkOps.filter(op => op !== null);

    if (validOps.length > 0) {
      // Executar o bulkWrite somente se houver operações válidas
      await News.bulkWrite(validOps);
      console.log(`${validOps.length} artigos foram processados e salvos com sucesso.`);
    } else {
      console.log('Nenhum artigo novo ou atualizado encontrado.');
    }
  } catch (error) {
    console.error('Erro ao buscar ou salvar notícias:', error.message);
  }
}

module.exports = fetchAndSaveNews;
