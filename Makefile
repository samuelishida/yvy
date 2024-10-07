# Define os alvos (targets)
.PHONY: build-frontend build-backend build-both rebuild-frontend rebuild-backend rebuild-all clean-volumes stop-frontend stop-backend stop-all run mongo-access

# Parar o frontend
stop-frontend:
	docker-compose stop frontend

# Parar o backend
stop-backend:
	docker-compose stop backend

# Parar todos os serviços
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
rebuild: stop-all
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
	docker run -it --rm --network host mongo:4.4-bionic mongo --host localhost --port 27017 -u root -p example