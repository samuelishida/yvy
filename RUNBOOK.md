# Yvy Runbook

## Environments

- Development: copy `.env.example` to `.env`, run `make setup`, then `make run`
- Production (baremetal OCI): deploy via Terraform + Ansible e valide os serviços `yvy-backend` e `yvy-frontend`

## Health checks

- Backend: `curl -f http://localhost:5000/health`
- Frontend: `curl -f http://localhost:5001/health`
- SQLite: `sqlite3 backend-lua/data/yvy.db ".tables"`

## Backups

### Local (dev machine)
- Run `./backup.sh` → `sqlite_backups/yvy_*.sqlite3.gz`

### Prod → desktop (automated, recommended)
- Desktop puller: `scripts/backup/pull-prod-backups.sh` — SSHes into the prod VM,
  snapshots the DB consistently (`sqlite3 .backup`, WAL-safe), pulls it to
  `~/yvy-backups/weekly/`.
- Installed as a weekly cron (Sunday 03:17) via `scripts/backup/install-backup-cron.sh`.
- Retention: keeps the last 2 backups (~2 weeks); nothing older is kept.
  Logs: `~/yvy-backups/backup.log`.
- Overrides (env): `PROD_VM_IP`, `SSH_KEY`, `LOCAL_BACKUP_DIR`,
  `WEEKLY_RETENTION`, `VERIFY_INTEGRITY`.
- Test restores regularly in a disposable environment before relying on the backup set.

## Restore procedure (from a prod backup)

1. Stop writers: `sudo systemctl stop yvy-backend` (prod) or the local backend.
2. Pick the archive: `ls -t ~/yvy-backups/weekly/ | head -1`
3. Restore locally:
   `gunzip -c ~/yvy-backups/daily/<backup>.sqlite3.gz > backend-lua/data/yvy.db`
   Or push to prod:
   `gunzip -c ~/yvy-backups/daily/<backup>.sqlite3.gz | ssh -i ~/.ssh/oci_yvy ubuntu@<IP> "cat > /opt/yvy/backend-lua/data/yvy.db"`
4. Validate: `sqlite3 backend-lua/data/yvy.db "SELECT COUNT(*) FROM fire_data;"`

## Deploy / rollback

1. Run the CI checks locally or via GitHub Actions.
2. Update `.env` with the target environment values.
3. Deploy with Terraform + Ansible (`bash scripts/deploy/deploy-local.sh`) or restart services (`sudo systemctl restart yvy-backend yvy-frontend`).
4. Verify `/health` on frontend and backend.
5. Roll back by checking out the previous git revision, rerunning `scripts/dev/setup-local.sh`, and restarting os serviços.

## Protected-area crossing (UC/TI)

Camadas de observabilidade sobre UCs (Unidades de Conservação) e TIs (Terras
Indígenas):

- **Dados:** vetores já embarcados no repo (`backend-lua/data/conservation_units.json`,
  `indigenous_lands.json`), carregados em memória no startup. Refresh manual:
  ICMBio shapefile / CNUC-MMA open data (UCs) e FUNAI geo-services (TIs).
- **CAR × UC/TI (grilagem):** `GET /api/car/protected-overlap?cod_imovel=` — estima a
  fração do imóvel dentro de áreas protegidas (amostragem por grade). Status
  `suspeito` quando ≥ `PROTECTED_OVERLAP_SUSPECT` (0.8). Cache Redis
  `car:protected:<COD>` (24h). Badge "Altamente Suspeito / Fraude" no painel de
  verificação de propriedade.
- **DETER × UC/TI (extração ilegal):** `tools/deter_protected_alerts.lua` (scan
  noturno via `deter_daily.sh`) cruza polígonos DETER com UCs/TIs por geometria
  (centroide, ou gate de cantos para cortes grandes ≥ `DETER_LARGE_CUT_KM2` km² com
  ≥ `DETER_CORNER_HITS` cantos do bbox dentro) e grava `alerts:deter_protected`
  (TTL 24h) para o `/api/alerts`.
- **Fogo × UC/TI:** foco dentro de UC/TI já é classificado como `crime`
  (`tools/classify_fires.lua`).
- **Env vars:** `PROTECTED_OVERLAP_SUSPECT`, `PROTECTED_OVERLAP_SAMPLES`,
  `PROTECTED_OVERLAP_MAX_SAMPLES`, `DETER_LARGE_CUT_KM2`, `DETER_CORNER_HITS`.
