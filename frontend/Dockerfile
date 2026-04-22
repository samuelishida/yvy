FROM python:3.13-slim

# Create non-root user for security
RUN useradd --create-home appuser

# Install only the healthcheck dependency needed in the runtime image
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./
COPY frontend.py ./
COPY start.sh ./start.sh

RUN pip install --no-cache-dir -r requirements.txt

RUN chmod +x /app/start.sh

# Switch to non-root user
USER appuser

EXPOSE 5001

CMD ["/app/start.sh"]
