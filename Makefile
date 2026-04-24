# Define os alvos (targets)
.PHONY: build-frontend build-backend build-both rebuild-frontend rebuild-backend rebuild clean stop-frontend stop-backend stop run run-frontend run-backend mongo-access

# Parar o frontend
stop-frontend:
	docker-compose stop frontend

# Parar o backend
stop-backend:
	docker-compose stop backend

# Iniciar a aplicação em modo de desenvolvimento com nodemon
dev:
	nodemon server.js

# Parar a aplicação
stop:
	docker-compose down

# Construir apenas o frontend
build-frontend: stop-frontend
	docker-compose build frontend
	docker-compose up -d frontend

# Construir apenas o backend
build-backend: stop-backend
	docker-compose build backend
	docker-compose up -d backend

# Construir ambos (frontend e backend)
build: stop-frontend stop-backend
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
rebuild: stop
	docker-compose build
	docker-compose up

# Remover todos os volumes e reconstruir tudo
clean:
	docker-compose down -v
	docker-compose build

# Executar todos os serviços
run:
	docker-compose up
run-frontend:
	docker-compose up -d frontend
run-backend:
	docker-compose up -d backend

# Acessar o MongoDB
mongo-access:
	docker-compose exec mongo sh -lc 'mongosh --authenticationDatabase admin -u "$$MONGO_INITDB_ROOT_USERNAME" -p "$$MONGO_INITDB_ROOT_PASSWORD" "$$MONGO_DATABASE"'
