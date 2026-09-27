#!/usr/bin/env bash
# Tail a service log: bash scripts/aws-logs.sh [emergency|priority|rescue] [--no-follow]
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows must not rewrite /ecs/... style arguments
SVC="${1:-rescue}"
REGION="${REGION:-ap-southeast-2}"
FOLLOW="--follow"
[ "${2:-}" = "--no-follow" ] && FOLLOW=""
# shellcheck disable=SC2086
aws logs tail "/ecs/sdr/$SVC" --region "$REGION" --since 15m $FOLLOW
