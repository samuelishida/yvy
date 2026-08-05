#!/usr/bin/env bash
#
# verify-gzip.sh — Guard that nginx gzip compression for the JSON/JS payloads
# Yvy relies on is not silently regressed.
#
# Two modes:
#   1. No-URL mode: assert the nginx template (source of truth) still declares
#      gzip for application/json and application/javascript. Safe to run in CI
#      with no network/credentials.
#   2. URL mode:     bash scripts/verify-gzip.sh <url> — curl the given URL with
#      Accept-Encoding: gzip and assert the response has Content-Encoding: gzip.
#
# Exit non-zero if any assertion fails.

set -euo pipefail

TEMPLATE="ansible/templates/yvy-nginx.conf.j2"

echo "== verify-gzip.sh =="

# --- Mode 1: template guard (always runs) --------------------------------------
if [ ! -f "$TEMPLATE" ]; then
    echo "FAIL: template not found at $TEMPLATE (run from repo root?)"
    exit 1
fi

for mime in "application/json" "application/javascript"; do
    if grep -q "$mime" "$TEMPLATE"; then
        echo "OK: template gzip_types includes $mime"
    else
        echo "FAIL: template gzip_types is missing $mime — gzip regression"
        exit 1
    fi
done

# --- Mode 2: URL gzip check (only if a URL arg is given) -----------------------
URL="${1:-}"
if [ -n "$URL" ]; then
    echo "Checking URL: $URL"
    # Capture headers; reject non-200 and missing/unexpected content-encoding.
    headers_file="$(mktemp)"
    trap 'rm -f "$headers_file"' EXIT

    status="$(
        curl -s -o /dev/null -D "$headers_file" \
            -H "Accept-Encoding: gzip" \
            -w "%{http_code}" \
            "$URL"
    )" || {
        echo "FAIL: curl to $URL failed"
        exit 1
    }

    if [ "$status" != "200" ]; then
        echo "FAIL: expected HTTP 200 but got $status"
        exit 1
    fi

    # Content-Encoding header (case-insensitive, may be gzip or gzip, br etc.)
    if grep -qi '^Content-Encoding:.*gzip' "$headers_file"; then
        echo "OK: response is gzip-encoded (Content-Encoding: gzip present)"
    else
        echo "FAIL: response is NOT gzip-encoded — compression not active"
        cat "$headers_file"
        exit 1
    fi
else
    echo "No URL arg — template guard only."
fi

echo "== verify-gzip.sh OK =="
