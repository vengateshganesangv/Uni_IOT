#!/usr/bin/env bash
# Stop and remove the local stack, including the generated throwaway certs volume.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose down --volumes --remove-orphans
echo "Local stack removed."
