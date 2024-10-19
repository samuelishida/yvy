#!/bin/bash

# Etapa 1: Instalação de dependências para o React
echo "Instalando dependências do frontend..."
cd /app/frontend
npm install

# Etapa 2: Build do React
echo "Construindo o frontend..."
npm run build

# Etapa 3: Configuração do servidor Express
echo "Instalando dependências do servidor Express..."
cd /app
npm install express

# Etapa 4: Copiando arquivos necessários
echo "Configurando servidor..."
cp ./frontend/build/server.js ./frontend/build/

# Etapa 5: Iniciando o servidor
echo "Iniciando o servidor Express..."
node frontend/build/server.js
