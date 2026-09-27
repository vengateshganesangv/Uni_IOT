#!/usr/bin/env bash
# Start the local stack (Mosquitto + 4 services). Usage: scripts/local-up.sh [priority_replicas]
set -euo pipefail
cd "$(dirname "$0")/.."
export PRIORITY_REPLICAS="${1:-${PRIORITY_REPLICAS:-1}}"
docker compose up -d --build
echo
echo "Priority replicas: $PRIORITY_REPLICAS   (Rescue is always 1)"
echo "Fire an event : node scripts/fire-event.js 90 90 90"
echo "Watch result  : docker compose logs -f rescue"
echo "Stop          : scripts/local-down.sh"
