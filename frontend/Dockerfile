FROM python:3.9-slim

# Install net-tools for netstat command
RUN apt-get update && apt-get install -y net-tools

# Diretório de trabalho no container
WORKDIR /app

# Copiar os arquivos necessários
COPY requirements.txt ./
COPY frontend.py ./

# Instalar as dependências do frontend
RUN pip install --no-cache-dir -r requirements.txt

# Expose the port the application will run on
EXPOSE 5001

# Comando para rodar o frontend
CMD ["python", "frontend.py"]
