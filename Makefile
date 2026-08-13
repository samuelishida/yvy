# Yvy Makefile — Lua-only stack

.PHONY: setup run lua stop test-lua migrate-lua sqlite-access setup-lua run-lua ingest-sinaflor sync-sinaflor ingest-mapbiomas sync-mapbiomas ingest-area-efetiva sync-area-efetiva ingest-embargo sync-embargo car-weekly area-efetiva-weekly mapbiomas-weekly

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

# ── Sinaflor (fogo permitido) ────────────────────────────────────────────────

ingest-sinaflor:
	python3 scripts/data/download_sinaflor_auth.py

sync-sinaflor:
	bash scripts/deploy/sync-sinaflor.sh

# ── MapBiomas Alerta (risk intelligence) ─────────────────────────────────────

ingest-mapbiomas:
	python3 scripts/data/download_mapbiomas_alerta.py

sync-mapbiomas:
	bash scripts/deploy/sync-mapbiomas.sh

# ── Área efetiva (risk intelligence) ──────────────────────────────────────────

ingest-area-efetiva:
	python3 scripts/data/compute_area_efetiva.py

sync-area-efetiva:
	bash scripts/deploy/sync-area-efetiva.sh

# ── Embargo IBAMA (risk intelligence) ─────────────────────────────────────────

ingest-embargo:
	python3 scripts/data/download_embargo.py

sync-embargo:
	bash scripts/deploy/sync-embargo.sh

# ── Ingestion automation (plan: ingestion-automation) ─────────────────────────
# Weekly dev-machine cron wrappers (manual/on-demand runs). The cron entries
# are installed by scripts/backup/install-ingestion-cron.sh.

mapbiomas-weekly:
	bash scripts/data/mapbiomas_weekly.sh

car-weekly:
	bash scripts/data/car_weekly.sh

area-efetiva-weekly:
	bash scripts/data/area_efetiva_weekly.sh

