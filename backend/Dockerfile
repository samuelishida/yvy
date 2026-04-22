# Usando a imagem Python base
FROM python:3.9-slim

# Instalar build tools (needed for gevent) + net-tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    net-tools \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Definir o diretório de trabalho no container
WORKDIR /app

# Copiar os arquivos necessários para o container
COPY requirements.txt ./
COPY backend.py ./

# Instalar as dependências do backend
RUN pip install --no-cache-dir -r requirements.txt

# Expor a porta em que o aplicativo será executado
EXPOSE 5000

# Comando para rodar o backend
CMD ["python", "backend.py"]
