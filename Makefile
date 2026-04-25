.PHONY: setup run backend frontend stop test sqlite-access

setup:
	bash scripts/setup-local.sh

run:
	bash scripts/run-local.sh

backend:
	bash scripts/run-backend.sh

frontend:
	bash scripts/run-frontend.sh

test:
	cd backend && $(shell [ -f venv/bin/python ] && echo venv/bin/python || echo $$HOME/.local/share/yvy-venv/bin/python) test_sqlite_manual.py

sqlite-access:
	@sqlite3 backend/data/yvy.db ".tables"

stop:
	@echo "Killing local Yvy processes..."
	@pkill -f "[h]ypercorn backend:app" 2>/dev/null || true
	@pkill -f "[p]ython backend.py" 2>/dev/null || true
	@pkill -f "[n]ode server.js" 2>/dev/null || true
	@pkill -f "[r]eact-scripts start" 2>/dev/null || true
	@if command -v lsof >/dev/null 2>&1; then pids=$$(lsof -tiTCP:5000 -sTCP:LISTEN 2>/dev/null || true); [ -z "$$pids" ] || kill $$pids 2>/dev/null || true; fi
	@if command -v lsof >/dev/null 2>&1; then pids=$$(lsof -tiTCP:5001 -sTCP:LISTEN 2>/dev/null || true); [ -z "$$pids" ] || kill $$pids 2>/dev/null || true; fi
	@echo "Local processes stopped."
