# Etapa de Build do React
FROM node:18 AS build
WORKDIR /app
COPY ./package.json ./ 
RUN npm install
COPY . . 
RUN npm run build

# Etapa do servidor Express
FROM node:18
WORKDIR /app
# Copia a pasta `build` gerada pelo React para o diretório `/app`
COPY --from=build /app/build ./build
# Copia o arquivo `server.js` para o diretório `/app`
COPY ./build/server.js ./
# Instala dependências necessárias (incluindo Express)
RUN npm install express

# Porta do servidor
EXPOSE 3000

# Comando para rodar o servidor Express
CMD ["node", "server.js"]
