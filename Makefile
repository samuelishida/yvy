# Yvy Makefile — Lua-only stack

.PHONY: setup run lua stop test-lua migrate-lua sqlite-access setup-lua run-lua

# ── Setup ──────────────────────────────────────────────────────────────────────

setup:
	bash scripts/dev/setup-local.sh

# ── Run ────────────────────────────────────────────────────────────────────────

run:
	bash scripts/dev/start-lua-stack.sh

# ── Lua backend targets ───────────────────────────────────────────────────────

setup-lua:
	bash scripts/dev/setup-lua.sh

run-lua:
	bash scripts/dev/run-lua.sh

test-lua:
	cd backend-lua && busted --verbose tests/*.lua

migrate-lua:
	cd backend-lua && lua5.1 app/migrate.lua

sqlite-access:
	@sqlite3 backend-lua/data/yvy.db ".tables"

stop:
	@echo "Stopping Yvy processes..."
	@bash scripts/dev/stop-lua-stack.sh
	@echo "Local processes stopped."
