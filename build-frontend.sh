#!/bin/bash

# Definir o diretório base do frontend
FRONTEND_DIR="./frontend"

# Verificar se o diretório existe
if [ ! -d "$FRONTEND_DIR" ]; then
  echo "O diretório frontend não foi encontrado. Verifique o caminho."
  exit 1
fi

# Ir para o diretório do frontend
cd $FRONTEND_DIR

# Passo 1: Instalar dependências
echo "Instalando dependências do frontend..."
npm install

# Passo 2: Build do frontend
echo "Construindo o frontend..."
npm run build

# Verificar se o build foi bem-sucedido
if [ $? -ne 0 ]; then
  echo "Erro ao construir o frontend."
  exit 1
fi

echo "Build do frontend concluído com sucesso!"
