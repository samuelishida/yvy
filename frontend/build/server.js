const express = require('express');
const path = require('path');
const app = express();

// Servir os arquivos estáticos do build do React
app.use(express.static(path.join(__dirname, 'build')));

app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'build', 'index.html'));
});

// Porta padrão do Railway
const PORT = process.env.PORT || 8080;
app.listen(PORT, () => {
  console.log(`Servidor frontend rodando na porta ${PORT}`);
});
