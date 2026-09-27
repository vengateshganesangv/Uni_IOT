#!/usr/bin/env bash
# Deploy the whole system to AWS (ECR + ECS Fargate + Priority autoscaling) with Terraform.
#
#   bash scripts/aws-start.sh [-y] [--test-broker] [--alb] [--no-spot]
#
#   -y             skip the confirmation prompt
#   --test-broker  TEST ONLY: run a Mosquitto broker inside the VPC and shadow the hard-coded HiveMQ hostname,
#                  so no HiveMQ account/credentials are needed. Broker behaviour = Mosquitto, not HiveMQ.
#   --alb          put an ALB in front of Emergency (~US$0.035/h extra, allows >1 Emergency task)
#   --no-spot      use on-demand Fargate for Emergency/Priority (default: Spot, ~70% cheaper)
#
# Region: ap-southeast-2 (forced by the CloudWatch client hard-coded in emergency_service.js:16). Override only if you
#         also change that line: REGION=... bash scripts/aws-start.sh
# HiveMQ credentials (real mode only): HIVEMQ_USERNAME / HIVEMQ_PASSWORD env vars, else read from a .env file in the
#         repo (./.env or <service>/.env), else prompted. Passed to Terraform via TF_VAR_*; Terraform state will contain
#         them -> keep infra/terraform/*.tfstate private.
# Access: only your current public IP (/32) may reach Emergency. Override with ALLOWED_CIDR=x.x.x.x/32.
# Cost:   billable while running. Run scripts/aws-terminate.sh when done.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/infra/terraform"
REGION="${REGION:-ap-southeast-2}"
ASSUME_YES=0; TEST_BROKER=false; ALB=false; SPOT=true
for a in "$@"; do
  case "$a" in
    -y) ASSUME_YES=1;;
    --test-broker) TEST_BROKER=true;;
    --alb) ALB=true;;
    --no-spot) SPOT=false;;
    *) echo "unknown option: $a"; exit 1;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH"; exit 1; }; }
need aws; need terraform; need docker; need curl
docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon is not running"; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"

# ---- HiveMQ credentials (not needed with --test-broker) ----
env_file_value() { # $1 = key
  for f in "$ROOT/.env" "$ROOT"/*/.env; do
    [ -f "$f" ] || continue
    v="$(grep -E "^$1=" "$f" | head -1 | cut -d= -f2- | tr -d '"\r' || true)"
    [ -n "$v" ] && { echo "$v"; return; }
  done
}
if [ "$TEST_BROKER" = true ]; then
  HIVEMQ_USERNAME=""; HIVEMQ_PASSWORD=""
else
  HIVEMQ_USERNAME="${HIVEMQ_USERNAME:-$(env_file_value HIVEMQ_USERNAME)}"
  HIVEMQ_PASSWORD="${HIVEMQ_PASSWORD:-$(env_file_value HIVEMQ_PASSWORD)}"
  if [ -z "$HIVEMQ_USERNAME" ]; then read -r -p "HiveMQ username: " HIVEMQ_USERNAME; fi
  if [ -z "$HIVEMQ_PASSWORD" ]; then read -r -s -p "HiveMQ password: " HIVEMQ_PASSWORD; echo; fi
fi
export TF_VAR_hivemq_username="$HIVEMQ_USERNAME" TF_VAR_hivemq_password="$HIVEMQ_PASSWORD"

# ---- who may call POST /emergency (unauthenticated, 1 request -> up to 100k MQTT messages) ----
if [ -z "${ALLOWED_CIDR:-}" ]; then
  MYIP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  ALLOWED_CIDR="$MYIP/32"
fi
TAG="$(date +%Y%m%d%H%M%S)"
export TF_VAR_allowed_cidr="$ALLOWED_CIDR" TF_VAR_region="$REGION" TF_VAR_image_tag="$TAG" \
       TF_VAR_use_test_broker="$TEST_BROKER" TF_VAR_enable_alb="$ALB" TF_VAR_use_fargate_spot="$SPOT"

cat <<EOF

=== Deploy plan ===
 AWS account : $ACCOUNT_ID  ($CALLER_ARN)
 Region      : $REGION   (CLI default region is ignored on purpose)
 Broker      : $([ "$TEST_BROKER" = true ] && echo "TEST broker (Mosquitto in the VPC; HiveMQ is NOT used)" || echo "real HiveMQ Cloud (hard-coded host)")
 Compute     : $([ "$SPOT" = true ] && echo "Fargate Spot" || echo "Fargate on-demand") for Emergency/Priority; Rescue$([ "$TEST_BROKER" = true ] && echo " and test broker") on-demand
 Entry point : $([ "$ALB" = true ] && echo "ALB" || echo "no ALB; Emergency public IP") restricted to $ALLOWED_CIDR
 Image tag   : $TAG
 Cost        : billable until terminated. Rough order: US\$0.05-0.10/h in the default lean mode (ESTIMATE; verify pricing).
               Biggest risk is forgetting to run scripts/aws-terminate.sh.
EOF
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed? [y/N] " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; exit 1; }
fi

cd "$TF_DIR"
terraform init -input=false

# Phase 1: ECR repositories only, so images exist before ECS services start.
echo; echo ">> Phase 1: ECR repositories"
terraform apply -input=false -auto-approve -target=aws_ecr_repository.svc

# Phase 2: build + push images (linux/amd64 to match the Fargate task definition).
echo; echo ">> Phase 2: build and push images"
REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

build_push() { # name  context_dir  dockerfile
  local repo="$REGISTRY/sdr/$1"
  echo "-- $1"
  docker build --platform linux/amd64 -f "$ROOT/$2/$3" -t "$repo:$TAG" "$ROOT/$2"
  docker push "$repo:$TAG"
}
build_push emergency Emergency_Request_Service Dockerfile
build_push priority  Priority_Service          Dockerfile.slim
build_push rescue    Rescue_Service            Dockerfile
[ "$TEST_BROKER" = true ] && build_push broker docker/mosquitto Dockerfile.aws

# Phase 3: everything else.
echo; echo ">> Phase 3: infrastructure"
terraform apply -input=false -auto-approve

echo; echo ">> Waiting for ECS services to become stable (up to ~10 min)"
SERVICES="emergency priority rescue"; [ "$TEST_BROKER" = true ] && SERVICES="$SERVICES broker"
# shellcheck disable=SC2086
aws ecs wait services-stable --cluster sdr --services $SERVICES --region "$REGION" || \
  echo "WARN: services not stable yet; check: bash scripts/aws-status.sh"

echo ">> Finding the Emergency endpoint"
URL=""
for i in $(seq 1 30); do
  URL="$(bash "$ROOT/scripts/aws-url.sh" 2>/dev/null || true)"
  [ -n "$URL" ] || { sleep 10; continue; }
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL/" || true)"
  case "$code" in 200|404) echo "Emergency is up at $URL (HTTP $code)"; break;; esac
  sleep 10
done

cat <<EOF

=== Deployed ===
 Emergency URL : ${URL:-<not ready; run: bash scripts/aws-url.sh>}
 Trigger event : EMERGENCY_URL=\$(bash scripts/aws-url.sh) node scripts/fire-event.js 90 90 90
 Watch result  : bash scripts/aws-logs.sh rescue        (look for "FLOOD EVENT RESULT")
 Watch scaling : bash scripts/aws-status.sh
 Tear down     : bash scripts/aws-terminate.sh          (stops ALL charges)
EOF
