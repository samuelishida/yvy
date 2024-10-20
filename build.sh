#!/bin/bash

# Definir possíveis caminhos para o arquivo npmrc
NPMRC_PATHS=(
  "/root/.npm"
  "/etc/npm"
  "/app/.npm"
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
export NODE_ENV=production

# Se o arquivo .npmrc não foi encontrado, criar um novo
if [ "$NPMRC_FOUND" = false ]; then
  echo "Nenhum arquivo .npmrc foi encontrado. Criando um novo em /root/.npmrc"
  echo "production=true" > /root/.npmrc
  echo "Arquivo .npmrc criado com 'production=true' em /root/.npmrc"
fi

# Continuar com o build do node 
cd node || { echo "Diretório 'node' não encontrado."; exit 1; }

npm audit fix --force
npm config set loglevel error

echo "Executando npm install --omit=dev..."
# Executar npm install com produção forçada
npm install --omit=dev

# Instalar querystring-es3 e craco, se ainda não estiverem instalados
npm install react-bootstrap bootstrap

npm install querystring-es3 @craco/craco --save


# Construir o node
echo "Construindo o node..."
npm run build

# Verificar se o build foi bem-sucedido
if [ $? -ne 0 ]; then
  echo "Erro ao construir o node."
  exit 1
fi

echo "Build do node concluído com sucesso!"
