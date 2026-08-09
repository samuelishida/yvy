# Yvy Runbook

## Environments

- Development: copy `.env.example` to `.env`, run `make setup`, then `make run`
- Production (baremetal OCI): deploy via Terraform + Ansible e valide os serviços `yvy-backend` e `yvy-frontend`

## Health checks

- Backend: `curl -f http://localhost:5000/health`
- Frontend: `curl -f http://localhost:5001/health`
- SQLite: `sqlite3 backend-lua/data/yvy.db ".tables"`

## Pré-cálculo CAR × UC/TI

O endpoint `/api/car/protected-overlap` lê resultados pré-calculados da tabela
`car_protected_overlap` no `car.db`. Se a row estiver ausente, stale ou com
`version_key` desatualizado, a rota recalcula on-the-fly (Monte-Carlo) e
grava de volta de forma throttled.

### Quando regenerar

1. **Após reimportar CAR** (`lua5.1 tools/import_car.lua <UF>`):
   o import apaga o pré-cálculo **apenas da UF reimportada**. Re-execute:
   ```bash
   cd backend-lua
   make warm-car-protected   # todas as UFs, sequential
   # ou, com paralelismo por UF (recomendado em produção):
   printf '%s\n' AC AL AM AP BA CE DF ES GO MA MG MS MT PA PB PE PI PR RJ RN RO RR RS SC SE SP TO \
     | xargs -P 8 -I{} lua5.1 tools/warm_car_protected_overlap.lua {}
   ```

2. **Após atualizar `conservation_units.json` / `indigenous_lands.json`**:
   o `version_key` muda; o próximo request de cada imóvel cairá no fallback
   live até o warm re-rodar. Re-execute o comando acima.

### Env vars relevantes

- `PROTECTED_OVERLAP_MIN_AREA_HA` (default `1.0`): imóveis com `area_ha` abaixo
  desse valor são pulados no batch e nunca auto-reparados pela rota.
- `PROTECTED_OVERLAP_STALE_DAYS` (default `30`): rows mais antigas que isso
  são tratadas como stale e recalculadas no primeiro request.
- `PROTECTED_OVERLAP_SAMPLES` entra no `version_key`; mudá-lo invalida o
  pré-cálculo existente.

### Backup e storage

- Na primeira execução (quando a tabela ainda não existe), o batch faz uma
  cópia do `car.db` para `car.db.warm-backup-YYYYMMDD-HHMMSS` antes de escrever.
- A tabela pode adicionar 100–500 MB ao `car.db` (estimativa: 100k imóveis ×
  1–5 KB de JSON por row). Monitore com `ls -lh backend-lua/data/car/car.db`.

### Troubleshooting

- `source="live"` em todos os requests: verifique se `warm_car_protected_overlap`
  rodou e se a coluna `version_key` bate com a das geometrias atuais.
- Warm muito lento: paralelize por UF (comando acima). Não adicionamos
  paralelismo in-process no script; subprocessos são crash-safe.

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

### Option A: Manual OCI CLI deploy (when GitHub Actions is stuck)

Use local OCI CLI to discover the VM IP and SSH in as `ubuntu`. Assumes:
- `oci` CLI installed and `~/.oci/config` with API key.
- SSH key at `~/.ssh/oci_yvy` (or `yvy-oci-deploy`).
- Services already installed via Terraform + Ansible.

```bash
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
INSTANCE_ID=$(oci compute instance list \
  -c ocid1.tenancy.oc1..aaaaaaaa5vfmx4xoxmfv577ibav5fk3ablvy56yo4arls7lvyrtbvcsohjha \
  --region sa-saopaulo-1 --lifecycle-state RUNNING \
  --query 'data[?"display-name"==`yvy-server`].id' --raw-output | tr -d '[]" ')
VM_IP=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" \
  --region sa-saopaulo-1 --query 'data[0]."public-ip"' --raw-output)
SSH="ssh -i ~/.ssh/oci_yvy -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$VM_IP"

# Pull, rebuild frontend, restart services
$SSH 'cd /opt/yvy && git pull origin main'
cat > /tmp/rebuild_yvy.sh << 'EOF'
#!/usr/bin/env bash
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
  nvm use 18
fi
cd /opt/yvy/frontend
npm ci
npm run build
EOF
scp -i ~/.ssh/oci_yvy -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  /tmp/rebuild_yvy.sh "ubuntu@$VM_IP:/tmp/rebuild_yvy.sh"
$SSH 'bash /tmp/rebuild_yvy.sh'
$SSH 'cd /opt/yvy && sudo systemctl restart yvy-backend yvy-frontend && sleep 3 && \
  sudo systemctl is-active yvy-backend yvy-frontend'

# Verify public HTTPS
curl -sk -o /dev/null -w "%{http_code}\n" "https://$VM_IP/"
```

### Option B: Terraform + Ansible

1. Run the CI checks locally or via GitHub Actions.
2. Update `.env` with the target environment values.
3. Deploy with `bash scripts/deploy/deploy-local.sh`.
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
