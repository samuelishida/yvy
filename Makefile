# Define os alvos (targets)
.PHONY: build-frontend build-backend build-both rebuild-frontend rebuild-backend rebuild clean stop-frontend stop-backend stop run run-frontend run-backend sqlite-access local-setup local-run local-backend local-frontend local-test local-stop

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

# Acessar o SQLite
sqlite-access:
	docker-compose exec backend sh -lc 'sqlite3 /app/data/yvy.db ".tables"'

# ─── Local Development (no Docker) ───────────────────────────────────────────

local-setup:
	bash scripts/setup-local.sh

local-run:
	bash scripts/run-local.sh

local-backend:
	bash scripts/run-backend.sh

local-frontend:
	bash scripts/run-frontend.sh

local-test:
	cd backend && $(shell [ -f venv/bin/python ] && echo venv/bin/python || echo $$HOME/.local/share/yvy-venv/bin/python) test_sqlite_manual.py

local-stop:
	@echo "Killing all local processes..."
	@pkill -9 -f "hypercorn|python backend|node server|react-scripts" 2>/dev/null || true
	@sleep 2
	@echo "Local processes stopped."
