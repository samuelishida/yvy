# Yvy Runbook

## Environments

- Development: copy `.env.example` to `.env`, run `make setup`, then `make run`
- Production (baremetal OCI): deploy via Terraform + Ansible e valide os serviços `yvy-backend` e `yvy-frontend`

## Health checks

- Backend: `curl -f http://localhost:5000/health`
- Frontend: `curl -f http://localhost:5001/health`
- SQLite: `sqlite3 backend/data/yvy.db ".tables"`

## Backups

- Run `./backup.sh`
- Store the resulting archive from `sqlite_backups/` in offsite storage
- Test restores regularly in a disposable environment before relying on the backup set

## Restore procedure

1. Stop writers to the database.
2. Pick the backup archive to restore.
3. Run `gunzip -c sqlite_backups/<backup>.sqlite3.gz > backend/data/yvy.db`
4. Validate with `sqlite3 backend/data/yvy.db "SELECT COUNT(*) FROM deforestation_data;"`

## Deploy / rollback

1. Run the CI checks locally or via GitHub Actions.
2. Update `.env` with the target environment values.
3. Deploy with Terraform + Ansible (`bash scripts/deploy-local.sh`) or restart services (`sudo systemctl restart yvy-backend yvy-frontend`).
4. Verify `/health` on frontend and backend.
5. Roll back by checking out the previous git revision, rerunning `scripts/setup-local.sh`, and restarting os serviços.
