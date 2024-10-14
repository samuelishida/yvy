# Stage 1: Build the React App
FROM node:18-slim as build

# Definir o diretório de trabalho
WORKDIR /app

# Copiar arquivos package.json e package-lock.json para instalar dependências
COPY package.json ./

# Instalar as dependências necessárias
RUN npm install

# Copiar todos os arquivos do projeto para o container
COPY . .

# Construir a aplicação para produção
RUN npm run build

# Stage 2: Serve the App with NGINX or Serve
FROM node:18-slim

# Diretório de trabalho para o servidor
WORKDIR /app

# Copiar o build da aplicação React para o container
COPY --from=build /app/build /app/build

# Instalar o pacote Serve globalmente para servir o build da aplicação
RUN npm install -g serve

# Copiar todos os arquivos do projeto para o container
COPY . .

# Copiar o script de entrada
COPY docker-entrypoint.sh /docker-entrypoint.sh

# Dar permissão de execução ao script de entrada
RUN chmod +x /docker-entrypoint.sh

# Expor a porta 3000
EXPOSE 3000

# Definir o script de entrada
ENTRYPOINT ["/docker-entrypoint.sh"]
