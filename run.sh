#!/bin/bash

# Definir o diretório base do frontend
FRONTEND_DIR="./node"

# Verificar se o diretório existe
if [ ! -d "$FRONTEND_DIR" ]; then
  echo "O diretório frontend não foi encontrado. Verifique o caminho."
  exit 1
fi

# Ir para o diretório do frontend
cd $FRONTEND_DIR

# Passo 1: Rodar o servidor
echo "Iniciando o servidor Express..."
node server.js

# Verificar se o servidor iniciou corretamente
if [ $? -ne 0 ]; then
  echo "Erro ao iniciar o servidor Express."
  exit 1
fi

echo "Servidor Express rodando com sucesso!"
