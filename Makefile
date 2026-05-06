# Yvy Makefile — Lua-only stack

.PHONY: setup run lua stop test-lua migrate-lua sqlite-access setup-lua run-lua

# ── Setup ──────────────────────────────────────────────────────────────────────

setup:
	bash scripts/setup-local.sh

# ── Run ────────────────────────────────────────────────────────────────────────

run:
	bash scripts/run-local.sh

# ── Lua backend targets ───────────────────────────────────────────────────────

setup-lua:
	bash scripts/setup-lua.sh

run-lua:
	bash scripts/run-lua.sh

test-lua:
	cd backend-lua && busted --verbose tests/*.lua

migrate-lua:
	cd backend-lua && lua scripts/migrate_to_jsonb.lua --db data/yvy.db --vacuum

sqlite-access:
	@sqlite3 backend-lua/data/yvy.db ".tables"

stop:
	@echo "Killing Yvy processes..."
	@pkill -f "lua main.lua" 2>/dev/null || true
	@pkill -f "yvy-server" 2>/dev/null || true
	@if command -v lsof >/dev/null 2>&1; then \
		pids=$$(lsof -tiTCP:5000 -sTCP:LISTEN 2>/dev/null || true); \
		[ -z "$$pids" ] || kill $$pids 2>/dev/null || true; \
		pids=$$(lsof -tiTCP:5001 -sTCP:LISTEN 2>/dev/null || true); \
		[ -z "$$pids" ] || kill $$pids 2>/dev/null || true; \
	fi
	@pkill -f "[r]eact-scripts start" 2>/dev/null || true
	@pkill -f "[n]ode.*react-scripts" 2>/dev/null || true
	@pkill -f "[n]ode server.js" 2>/dev/null || true
	@echo "Local processes stopped."
