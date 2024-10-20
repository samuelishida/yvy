#!/bin/bash

# Definir possíveis caminhos para o arquivo npmrc
NPMRC_PATHS=(
  "/root/.npmrc"
  "/etc/npmrc"
  "/app/.npmrc"
)

# Loop para verificar cada caminho dentro do contêiner
NPMRC_FOUND=false
for NPMRC_PATH in "${NPMRC_PATHS[@]}"; do
  # Verificar se o arquivo existe
  if [ -f "$NPMRC_PATH" ]; then
    NPMRC_FOUND=true
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

npm config set production true
npm config set loglevel error


# Se o arquivo .npmrc não foi encontrado, criar um novo
if [ "$NPMRC_FOUND" = false ]; then
  echo "Nenhum arquivo .npmrc foi encontrado. Criando um novo em /root/.npmrc"
  echo "production=true" > /root/.npmrc
  echo "Arquivo .npmrc criado com 'production=true' em /root/.npmrc"
fi

# Continuar com o build do frontend
cd frontend || { echo "Diretório 'frontend' não encontrado."; exit 1; }


echo "Executando npm install --omit=dev..."
# Executar npm install com produção forçada
npm install --omit=dev --production=true



# Construir o frontend
echo "Construindo o frontend..."
npm run build

# Verificar se o build foi bem-sucedido
if [ $? -ne 0 ]; then
  echo "Erro ao construir o frontend."
  exit 1
fi

echo "Build do frontend concluído com sucesso!"
