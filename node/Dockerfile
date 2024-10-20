# Usar uma imagem oficial do Node.js como base
FROM node:18-alpine

# Definir o diretório de trabalho dentro do contêiner
WORKDIR /app

# Copiar os arquivos do projeto para dentro do contêiner
COPY . .

# Executar o primeiro script bash para configurar o npmrc e instalar dependências
RUN chmod +x /app/first-script.sh && /app/first-script.sh

# Expor a porta do servidor Express (geralmente 3000, ajuste se necessário)
EXPOSE 3000

# Executar o segundo script bash para rodar o servidor Express
CMD ["/bin/bash", "/app/second-script.sh"]
