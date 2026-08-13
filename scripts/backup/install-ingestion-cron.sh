#!/usr/bin/env bash
# install-ingestion-cron.sh — Installs the dev-machine weekly cron entries for
# the ingestion automation (plan: ingestion-automation, Inc 1/5/6).
#
# The heavy jobs (MapBiomas, CAR, Area efetiva) run on the DEV machine via cron
# (5am, so the user is not on the PC). Light jobs (embargo/sinaflor/aux) run on
# the prod VM via systemd timers (see ansible/playbook.yml).
#
# Schedules (staggered so they don't contend for CPU/network on dev):
#   mapbiomas_weekly.sh    0 5 * * 1   (Monday 05:00)
#   car_weekly.sh          30 5 * * 1  (Monday 05:30)
#   area_efetiva_weekly.sh 0 6 * * 1   (Monday 06:00)
#
# Idempotent: replaces any previous entry for the same wrapper (grep before
# append), so re-running keeps the schedule fresh.
#
#   CRON_TIME_MAPBIOMAS="0 5 * * 1"   # override per-job schedule
#   CRON_TIME_CAR="30 5 * * 1"
#   CRON_TIME_AREA_EFETIVA="0 6 * * 1"
#   bash scripts/backup/install-ingestion-cron.sh
#
# To remove later:  crontab -e   and delete the lines containing the wrappers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

MAPBIOMAS_WRAPPER="$PROJECT_DIR/scripts/data/mapbiomas_weekly.sh"
CAR_WRAPPER="$PROJECT_DIR/scripts/data/car_weekly.sh"
AREA_EFETIVA_WRAPPER="$PROJECT_DIR/scripts/data/area_efetiva_weekly.sh"

CRON_TIME_MAPBIOMAS="${CRON_TIME_MAPBIOMAS:-0 5 * * 1}"
CRON_TIME_CAR="${CRON_TIME_CAR:-30 5 * * 1}"
CRON_TIME_AREA_EFETIVA="${CRON_TIME_AREA_EFETIVA:-0 6 * * 1}"
LOG_DIR="${LOG_DIR:-$HOME/yvy-ingestion}"

mkdir -p "$LOG_DIR"

# Only install entries whose wrapper exists (CAR/area-efetiva land in Inc 5/6).
declare -a LINES=()
if [[ -f "$MAPBIOMAS_WRAPPER" ]]; then
  LINES+=("$CRON_TIME_MAPBIOMAS PATH=/usr/local/bin:/usr/bin:/bin /bin/bash '$MAPBIOMAS_WRAPPER' >> '$LOG_DIR/mapbiomas.log' 2>&1")
fi
if [[ -f "$CAR_WRAPPER" ]]; then
  LINES+=("$CRON_TIME_CAR PATH=/usr/local/bin:/usr/bin:/bin /bin/bash '$CAR_WRAPPER' >> '$LOG_DIR/car.log' 2>&1")
fi
if [[ -f "$AREA_EFETIVA_WRAPPER" ]]; then
  LINES+=("$CRON_TIME_AREA_EFETIVA PATH=/usr/local/bin:/usr/bin:/bin /bin/bash '$AREA_EFETIVA_WRAPPER' >> '$LOG_DIR/area_efetiva.log' 2>&1")
fi

if [[ ${#LINES[@]} -eq 0 ]]; then
  echo "No ingestion wrappers found yet — nothing to install." >&2
  exit 0
fi

# Replace any existing entries for these wrappers (idempotent, keeps schedule fresh).
CURRENT="$(crontab -l 2>/dev/null || true)"
for wrapper in "$MAPBIOMAS_WRAPPER" "$CAR_WRAPPER" "$AREA_EFETIVA_WRAPPER"; do
  CURRENT="$(printf '%s\n' "$CURRENT" | grep -vF "$wrapper" || true)"
done
{ printf '%s\n' "$CURRENT"; printf '%s\n' "${LINES[@]}"; } | crontab -
echo "Cron entries set:"
printf '  %s\n' "${LINES[@]}"

echo
echo "Logs land in $LOG_DIR/ (mapbiomas.log, car.log, area_efetiva.log)."
echo "Manual run: bash '$MAPBIOMAS_WRAPPER'"
