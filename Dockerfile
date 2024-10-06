FROM python:3.9-slim

# Define o diretório de trabalho
WORKDIR /usr/src/app

# Copia o arquivo de requisitos e instala as dependências
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copia o script Python para o container
COPY main.py .

# Comando para rodar o script
CMD ["python", "main.py"]
