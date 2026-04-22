# Yvy Runbook

## Environments

- Development: copy `.env.dev.example` to `.env` and run `docker-compose up --build`
- Production: copy `.env.prod.example` to `.env`, replace every placeholder secret, then run `docker-compose up --build -d`

## Health checks

- Backend: `curl -f http://localhost:5000/health`
- Frontend: `curl -f http://localhost:5001/health`
- MongoDB: `docker-compose exec mongo mongosh --eval "db.adminCommand('ping')"`

## Backups

- Run `./backup.sh`
- Store the resulting archive from `mongo_backups/` in offsite storage
- Test restores regularly with a disposable MongoDB instance before relying on the backup set

## Restore procedure

1. Stop writers to the database.
2. Pick the backup archive to restore.
3. Run `gunzip -c mongo_backups/<backup>.gz | docker-compose exec -T mongo mongorestore --authenticationDatabase admin --username "$MONGO_ROOT_USERNAME" --password "$MONGO_ROOT_PASSWORD" --archive --gzip --drop`
4. Validate with `docker-compose exec mongo mongosh "$MONGO_DATABASE" --eval "db.deforestation_data.countDocuments({})"`

## Deploy / rollback

1. Run the CI checks locally or via GitHub Actions.
2. Update `.env` with the target environment values.
3. Run `docker-compose up --build -d`.
4. Verify `/health` on frontend and backend.
5. Roll back by redeploying the previous image or git revision and re-running the health checks.
