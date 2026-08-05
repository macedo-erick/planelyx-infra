#!/usr/bin/env bash
#
# Pull the pinned images and restart the stack. Run from the VPS.
#
# Not zero-downtime: the API restarts in place and Flyway runs on startup, so expect a few
# seconds of 502 on /api during a deploy.
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
    echo "error: .env not found. Copy .env.example and fill it in." >&2
    exit 1
fi

docker compose -f compose.prod.yaml pull
docker compose -f compose.prod.yaml up -d --remove-orphans
docker image prune -f

echo
docker compose -f compose.prod.yaml ps
