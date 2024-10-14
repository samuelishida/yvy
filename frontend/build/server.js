const path = require('path');
const express = require('express');
const app = express();

const buildPath = path.join(__dirname, 'build');
app.use(express.static(buildPath));

// Adicione esta rota para capturar todas as requisições que não correspondem a rotas de arquivos estáticos
app.get('*', (req, res) => {
  res.sendFile(path.join(buildPath, 'index.html'));
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
