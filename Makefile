# Define os alvos (targets)
.PHONY: build-frontend build-backend build-both rebuild-frontend rebuild-backend rebuild-all clean-volumes stop-frontend stop-backend stop-all run mongo-access install-docker

# Instalar o Docker (baseado em sistema Debian/Ubuntu)
install-docker:
	@echo "Instalando Docker..."
	@apt-get update
	@apt-get install -y \
	    ca-certificates \
	    curl \
	    gnupg \
	    lsb-release
	@mkdir -p /etc/apt/keyrings
	@curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	@echo \
	  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
	  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
	@apt-get update
	@apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

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
build-frontend: install-docker stop-frontend
	docker-compose build frontend
	docker-compose up -d frontend

# Construir apenas o backend
build-backend: install-docker stop-backend
	docker-compose build backend
	docker-compose up -d backend

# Construir ambos (frontend e backend)
build: install-docker stop-frontend stop-backend
	docker-compose build frontend backend

# Reconstruir apenas o frontend (derruba e reconstrói)
rebuild-frontend: install-docker stop-frontend
	docker-compose rm -f frontend
	docker-compose build frontend
	docker-compose up -d frontend

# Reconstruir apenas o backend (derruba e reconstrói)
rebuild-backend: install-docker stop-backend
	docker-compose rm -f backend
	docker-compose build backend
	docker-compose up -d backend

# Reconstruir todos os serviços (frontend, backend, etc.)
rebuild: install-docker stop-all
	docker-compose build
	docker-compose up

# Remover todos os volumes e reconstruir tudo
clean: install-docker
	docker-compose down --remove-orphans
	rm -rf ./mongo_data

# Executar todos os serviços
run: install-docker
	docker-compose up

run-frontend: install-docker
	docker-compose up -d frontend

run-backend: install-docker
	docker-compose up -d backend

# Acessar o MongoDB
mongo-access: install-docker
	docker run -it --rm --network host mongo:4.4-bionic mongo --host localhost --port 27017 -u root -p example
