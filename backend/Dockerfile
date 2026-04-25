# Usando a imagem Python base (Python 3.13 - atualizado)
FROM python:3.13-slim

# Create non-root user for security
RUN useradd --create-home appuser

# Install only the healthcheck dependency needed in the runtime image
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Create data directory for SQLite (must be writable by appuser)
RUN mkdir -p /app/data && chown appuser:appuser /app/data

# Copy requirements and source
COPY requirements.txt ./
COPY backend.py ./
COPY db_sqlite.py ./
COPY news_sqlite.py ./
COPY ingest_sqlite.py ./
COPY start.sh ./start.sh

# Install Python deps
RUN pip install --no-cache-dir -r requirements.txt

RUN chmod +x /app/start.sh

# Switch to non-root user
USER appuser

EXPOSE 5000

CMD ["/app/start.sh"]
