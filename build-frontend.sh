#!/bin/bash

# Definir possíveis caminhos para o arquivo npmrc no contêiner
NPMRC_PATHS=(
  "/root/.npmrc"
  "/etc/npmrc"
  "/app/.npmrc"
)

# Loop para verificar cada caminho dentro do contêiner
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

# Continue com o build do frontend
cd frontend && npm run install:prod && npm run build

echo "Build do frontend concluído com sucesso!"