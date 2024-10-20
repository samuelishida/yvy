const express = require('express');
const path = require('path');
const app = express();

// Definir o caminho correto para a pasta 'build'
const buildPath = path.join(__dirname, 'frontend');

// Servir os arquivos estáticos do build do React
app.use(express.static(buildPath));

app.get('*', (req, res) => {
  res.sendFile(path.join(buildPath, 'index.html'));
});

// Porta padrão do Railway
const PORT = process.env.PORT || 8080;
app.listen(PORT, () => {
  console.log(`Servidor frontend rodando na porta ${PORT}`);
});
