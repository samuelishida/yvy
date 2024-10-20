#!/bin/bash

# Definir possíveis caminhos para o arquivo npmrc
NPMRC_PATHS=(
  "$HOME/.npmrc"
  "/etc/npmrc"
)

# Loop para verificar cada caminho
for NPMRC_PATH in "${NPMRC_PATHS[@]}"; do
  # Verificar se o arquivo existe
  if [ -f "$NPMRC_PATH" ]; then
    echo "Arquivo npmrc encontrado em: $NPMRC_PATH"
    
    # Verificar se o arquivo contém a linha "production=false"
    if grep -q "production=false" "$NPMRC_PATH"; then
      echo "Removendo a linha 'production=false'..."
      
      # Usar sed para remover a linha contendo "production=false"
      sed -i '/production=false/d' "$NPMRC_PATH"
      
      echo "Linha removida com sucesso de $NPMRC_PATH."
    else
      echo "A linha 'production=false' não foi encontrada em $NPMRC_PATH."
    fi
  else
    echo "Arquivo npmrc não encontrado em: $NPMRC_PATH"
  fi
done

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
