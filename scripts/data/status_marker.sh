#!/usr/bin/env bash
# status_marker.sh — writes a per-source status file after an ingestion job.
#
# The DB mtime remains the PRIMARY success marker (common-mistake #5); this
# status file adds human-readable last-run observability. Best-effort: a
# status-write failure is non-fatal.
#
# Usage:
#   source scripts/data/status_marker.sh
#   write_status <source> <ok|fail>
#
# Writes <data_dir>/<source>/.last_sync with:
#   source: <name>
#   result: <ok|fail>
#   at: <ISO timestamp>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATUS_DIR="${STATUS_DIR:-$PROJECT_DIR/backend-lua/data}"

write_status() {
  local source="${1:-}"
  local result="${2:-ok}"
  if [[ -z "$source" ]]; then
    echo "write_status: missing source" >&2
    return 1
  fi
  local dir="$STATUS_DIR/$source"
  mkdir -p "$dir" 2>/dev/null || return 0
  {
    echo "source: $source"
    echo "result: $result"
    echo "at: $(date -u +%FT%TZ)"
  } > "$dir/.last_sync" 2>/dev/null || return 0
}
