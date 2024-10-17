.PHONY: build-frontend build-backend build-both rebuild-frontend rebuild-backend rebuild-all clean-volumes stop-frontend stop-backend stop-mongo stop-all run run-frontend run-backend mongo-access

# Variáveis de configuração
NETWORK=app-network

# MongoDB Configurações
MONGO_CONTAINER=mongo
MONGO_IMAGE=mongo:latest
MONGO_PORT=27017
MONGO_INIT_SCRIPT=./mongo-init.js
MONGO_DATA=./mongo_data
MONGO_USER=root
MONGO_PASSWORD=example

# Frontend Configurações
FRONTEND_CONTAINER=frontend
FRONTEND_IMAGE=frontend:latest
FRONTEND_PORT=3000
FRONTEND_CONTEXT=./frontend

# Backend Configurações
BACKEND_CONTAINER=backend
BACKEND_IMAGE=backend:latest
BACKEND_PORT=5000
BACKEND_CONTEXT=./backend
BACKEND_ENV_MONGO_URI=mongodb://$(MONGO_USER):$(MONGO_PASSWORD)@yvy.railway.internal:27017/

# Função para criar a rede se não existir
create-network:
	@docker network ls | grep $(NETWORK) > /dev/null 2>&1 || docker network create $(NETWORK)

# Função para construir a imagem do frontend
build-frontend: stop-frontend create-network
	@docker build -t $(FRONTEND_IMAGE) $(FRONTEND_CONTEXT)
	@docker run -d \
		--name $(FRONTEND_CONTAINER) \
		--network $(NETWORK) \
		-p $(FRONTEND_PORT):3000 \
		--cpus="1.0" \
		$(FRONTEND_IMAGE)

# Função para construir a imagem do backend
build-backend: stop-backend create-network
	@docker build -t $(BACKEND_IMAGE) $(BACKEND_CONTEXT)
	@docker run -d \
		--name $(BACKEND_CONTAINER) \
		--network $(NETWORK) \
		-p $(BACKEND_PORT):5000 \
		-e MONGO_URI=$(BACKEND_ENV_MONGO_URI) \
		-v $(BACKEND_CONTEXT):/app \
		--cpus="1.0" \
		$(BACKEND_IMAGE)

# Função para construir ambos frontend e backend
build-both: build-frontend build-backend

# Função para construir todos os serviços (incluindo MongoDB)
build-all: stop-all create-network
	@docker build -t $(FRONTEND_IMAGE) $(FRONTEND_CONTEXT)
	@docker build -t $(BACKEND_IMAGE) $(BACKEND_CONTEXT)
	@docker run -d \
		--name $(MONGO_CONTAINER) \
		--network $(NETWORK) \
		-e MONGO_INITDB_ROOT_USERNAME=$(MONGO_USER) \
		-e MONGO_INITDB_ROOT_PASSWORD=$(MONGO_PASSWORD) \
		-p $(MONGO_PORT):27017 \
		-v $(MONGO_INIT_SCRIPT):/docker-entrypoint-initdb.d/mongo-init.js:ro \
		-v $(MONGO_DATA):/data/db \
		--cpus="1.0" \
		$(MONGO_IMAGE)
	@docker run -d \
		--name $(BACKEND_CONTAINER) \
		--network $(NETWORK) \
		-p $(BACKEND_PORT):5000 \
		-e MONGO_URI=$(BACKEND_ENV_MONGO_URI) \
		-v $(BACKEND_CONTEXT):/app \
		--cpus="1.0" \
		$(BACKEND_IMAGE)
	@docker run -d \
		--name $(FRONTEND_CONTAINER) \
		--network $(NETWORK) \
		-p $(FRONTEND_PORT):3000 \
		--cpus="1.0" \
		$(FRONTEND_IMAGE)

# Função para reconstruir apenas o frontend
rebuild-frontend: stop-frontend
	@docker rm -f $(FRONTEND_CONTAINER) > /dev/null 2>&1 || true
	@docker build -t $(FRONTEND_IMAGE) $(FRONTEND_CONTEXT)
	@docker run -d \
		--name $(FRONTEND_CONTAINER) \
		--network $(NETWORK) \
		-p $(FRONTEND_PORT):3000 \
		--cpus="1.0" \
		$(FRONTEND_IMAGE)

# Função para reconstruir apenas o backend
rebuild-backend: stop-backend
	@docker rm -f $(BACKEND_CONTAINER) > /dev/null 2>&1 || true
	@docker build -t $(BACKEND_IMAGE) $(BACKEND_CONTEXT)
	@docker run -d \
		--name $(BACKEND_CONTAINER) \
		--network $(NETWORK) \
		-p $(BACKEND_PORT):5000 \
		-e MONGO_URI=$(BACKEND_ENV_MONGO_URI) \
		-v $(BACKEND_CONTEXT):/app \
		--cpus="1.0" \
		$(BACKEND_IMAGE)

# Função para reconstruir todos os serviços
rebuild-all: stop-all
	$(MAKE) build-all

# Função para parar o frontend
stop-frontend:
	@docker stop $(FRONTEND_CONTAINER) > /dev/null 2>&1 || true
	@docker rm $(FRONTEND_CONTAINER) > /dev/null 2>&1 || true

# Função para parar o backend
stop-backend:
	@docker stop $(BACKEND_CONTAINER) > /dev/null 2>&1 || true
	@docker rm $(BACKEND_CONTAINER) > /dev/null 2>&1 || true

# Função para parar o MongoDB
stop-mongo:
	@docker stop $(MONGO_CONTAINER) > /dev/null 2>&1 || true
	@docker rm $(MONGO_CONTAINER) > /dev/null 2>&1 || true

# Função para parar todos os serviços
stop-all: stop-frontend stop-backend stop-mongo

# Função para executar todos os serviços
run: build-all

# Função para executar apenas o frontend
run-frontend: build-frontend

# Função para executar apenas o backend
run-backend: build-backend

# Função para acessar o MongoDB
mongo-access:
	@docker run -it --rm --network $(NETWORK) $(MONGO_IMAGE) mongo \
		--host yvy.railway.internal \
		--port $(MONGO_PORT) \
		-u $(MONGO_USER) \
		-p $(MONGO_PASSWORD)

# Função para limpar volumes e dados
clean-volumes: stop-all
	@docker volume prune -f
	@rm -rf $(MONGO_DATA)
