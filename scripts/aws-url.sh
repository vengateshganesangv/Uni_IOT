#!/usr/bin/env bash
# Print the base URL of the Emergency Request Service on AWS.
#   ALB deployment    -> http://<alb-dns>
#   no-ALB deployment -> http://<public-ip-of-the-running-task>:3001   (changes if the task is replaced, e.g. Spot interruption)
# Usage: EMERGENCY_URL=$(bash scripts/aws-url.sh) node scripts/fire-event.js 90 90 90
set -euo pipefail
export MSYS_NO_PATHCONV=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${REGION:-ap-southeast-2}"

ALB_URL="$(cd "$ROOT/infra/terraform" && terraform output -raw emergency_url 2>/dev/null || true)"
if [ -n "$ALB_URL" ]; then echo "$ALB_URL"; exit 0; fi

TASK="$(aws ecs list-tasks --cluster sdr --service-name emergency --desired-status RUNNING --region "$REGION" \
  --query 'taskArns[0]' --output text)"
[ -n "$TASK" ] && [ "$TASK" != "None" ] || { echo "ERROR: no running emergency task yet" >&2; exit 1; }
ENI="$(aws ecs describe-tasks --cluster sdr --tasks "$TASK" --region "$REGION" \
  --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text)"
IP="$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --region "$REGION" \
  --query 'NetworkInterfaces[0].Association.PublicIp' --output text)"
[ -n "$IP" ] && [ "$IP" != "None" ] || { echo "ERROR: task has no public IP yet" >&2; exit 1; }
echo "http://$IP:3001"
