require('dotenv').config();

const express = require('express');
const path = require('path');

// Importar as funções do backend
const connectToMongoDB = require('./backend/mongo');
const fetchAndSaveNews = require('./backend/news-api');

const app = express();
const cors = require('cors');
const cron = require('node-cron');

app.use(cors());

// Conectar ao MongoDB
connectToMongoDB();

// Agendar a atualização das notícias a cada 5 minutos
cron.schedule('*/5 * * * *', async () => {
  console.log('Iniciando a atualização das notícias...');
  try {
    await fetchAndSaveNews();
    console.log('Atualização de notícias concluída com sucesso.');
  } catch (error) {
    console.error('Erro ao atualizar notícias:', error.message);
  }
});

// Executar a atualização das notícias na inicialização
fetchAndSaveNews();

// Endpoint para fornecer as notícias ao frontend
const News = require('./models/News');

app.get('/api/news', async (req, res) => {
  try {
    const articles = await News.find().sort({ publishedAt: -1 }).limit(100);
    res.json(articles);
  } catch (error) {
    console.error('Erro ao obter notícias:', error.message);
    res.status(500).json({ message: 'Erro ao obter notícias' });
  }
});

// Servir os arquivos estáticos do React
app.use(express.static(path.join(__dirname, 'build')));

// Rota para servir o aplicativo React
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'build', 'index.html'));
});

// Iniciar o servidor
const PORT = process.env.PORT || 8080;
app.listen(PORT, () => {
  console.log(`Servidor rodando na porta ${PORT}`);
});