# Define os alvos (targets)
.PHONY: build-frontend build-backend build-both rebuild-frontend rebuild-backend rebuild-all clean-volumes stop-frontend stop-backend stop-all

# Parar o frontend
stop-frontend:
	docker-compose stop frontend

# Parar o backend
stop-backend:
	docker-compose stop backend

# Parar todos os serviços
stop-all:
	docker-compose down

# Construir apenas o frontend
build-frontend: stop-frontend
	docker-compose build frontend

# Construir apenas o backend
build-backend: stop-backend
	docker-compose build backend

# Construir ambos (frontend e backend)
build-both: stop-frontend stop-backend
	docker-compose build frontend backend

# Reconstruir apenas o frontend (derruba e reconstrói)
rebuild-frontend: stop-frontend
	docker-compose rm -f frontend
	docker-compose build frontend

# Reconstruir apenas o backend (derruba e reconstrói)
rebuild-backend: stop-backend
	docker-compose rm -f backend
	docker-compose build backend

# Reconstruir todos os serviços (frontend, backend, etc.)
rebuild-all: stop-all
	docker-compose build
	docker-compose up -d

# Remover todos os volumes e reconstruir tudo
clean-volumes:
	docker-compose down -v
	docker-compose build
	docker-compose up -d
