# Usando a imagem Python base (Python 3.13 - atualizado)
FROM python:3.13-slim

# Create non-root user for security
RUN useradd --create-home appuser

# Install only the healthcheck dependency needed in the runtime image
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy requirements and source
COPY requirements.txt ./
COPY backend.py ./
COPY ingest.py ./ingest.py
COPY start.sh ./start.sh

# Install Python deps (includes gunicorn)
RUN pip install --no-cache-dir -r requirements.txt

RUN chmod +x /app/start.sh

# Switch to non-root user
USER appuser

EXPOSE 5000

CMD ["/app/start.sh"]
