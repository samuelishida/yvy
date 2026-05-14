#!/usr/bin/env bash
# ansible-check.sh — Validate ansible/playbook.yml locally before pushing.
# Runs syntax-check + lint against a stub inventory (no real SSH needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

ANSIBLE_PLAYBOOK=$(command -v ansible-playbook 2>/dev/null \
    || echo "$HOME/.local/bin/ansible-playbook")
ANSIBLE_LINT=$(command -v ansible-lint 2>/dev/null \
    || echo "$HOME/.local/bin/ansible-lint")

if [ ! -x "$ANSIBLE_PLAYBOOK" ]; then
    echo "ansible-playbook not found. Install: pip3 install --user ansible ansible-lint"
    exit 1
fi

INVENTORY=$(mktemp /tmp/yvy-inventory.XXXXXX.ini)
trap 'rm -f "$INVENTORY"' EXIT
printf '[yvy]\n127.0.0.1 ansible_user=ubuntu ansible_connection=local\n' > "$INVENTORY"

echo "=== Ansible syntax check ==="
"$ANSIBLE_PLAYBOOK" --syntax-check -i "$INVENTORY" "$PROJECT_DIR/ansible/playbook.yml"
echo "Syntax OK"

if [ -x "$ANSIBLE_LINT" ]; then
    echo ""
    echo "=== ansible-lint ==="
    "$ANSIBLE_LINT" --profile=min "$PROJECT_DIR/ansible/playbook.yml" \
        -i "$INVENTORY" || true
else
    echo "(ansible-lint not found, skipping — install: pip3 install --user ansible-lint)"
fi
