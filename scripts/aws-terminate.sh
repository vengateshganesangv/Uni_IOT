#!/usr/bin/env bash
# Destroy everything created by aws-start.sh and verify nothing billable is left.
#
#   bash scripts/aws-terminate.sh [-y]
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows must not rewrite /ecs/... style arguments

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/infra/terraform"
REGION="${REGION:-ap-southeast-2}"
ASSUME_YES=0
[ "${1:-}" = "-y" ] && ASSUME_YES=1

command -v terraform >/dev/null || { echo "ERROR: terraform not found"; exit 1; }
command -v aws >/dev/null || { echo "ERROR: aws not found"; exit 1; }

cd "$TF_DIR"
if [ ! -f terraform.tfstate ] || [ -z "$(terraform state list 2>/dev/null || true)" ]; then
  echo "Terraform state is empty: nothing recorded as deployed from this machine."
else
  echo "Resources that will be destroyed:"
  terraform state list | sed 's/^/  /'
  if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Destroy ALL of the above in $REGION? [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; exit 1; }
  fi

  # Variable values are required by the config but irrelevant for destroy.
  terraform destroy -input=false -auto-approve \
    -var region="$REGION" -var hivemq_username=destroy -var hivemq_password=destroy -var allowed_cidr=0.0.0.0/32
fi

echo
echo ">> Verifying nothing tagged Project=sdr is left in $REGION"
LEFT="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters Key=Project,Values=sdr --query 'ResourceTagMappingList[].ResourceARN' --output text || true)"
if [ -z "$LEFT" ]; then
  echo "Clean: no tagged resources remain."
else
  echo "Still listed (the tagging API can lag a few minutes; re-run this script to re-check):"
  echo "$LEFT" | tr '\t' '\n' | sed 's/^/  /'
fi

# Not tag-visible resources
echo ">> ECR repos / log groups / SSM params with the sdr prefix:"
aws ecr describe-repositories --region "$REGION" --query 'repositories[?starts_with(repositoryName,`sdr/`)].repositoryName' --output text || true
aws logs describe-log-groups --region "$REGION" --log-group-name-prefix /ecs/sdr --query 'logGroups[].logGroupName' --output text || true
aws ssm get-parameters-by-path --region "$REGION" --path /sdr --recursive --query 'Parameters[].Name' --output text || true
echo "(empty lines above = none left)"
echo
echo "Note: the CloudWatch custom metric SmartDisasterRelief/IncomingRequests cannot be deleted; it expires on its own and costs nothing without new data."
