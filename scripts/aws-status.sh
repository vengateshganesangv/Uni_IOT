#!/usr/bin/env bash
# Show ECS task counts, autoscaling target and alarm states. Re-run (or `watch -n 10`) while firing events.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows must not rewrite /ecs/... style arguments
REGION="${REGION:-ap-southeast-2}"

echo "== ECS services (cluster sdr)"
aws ecs describe-services --cluster sdr --services emergency priority rescue --region "$REGION" \
  --query 'services[].{service:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount}' --output table

echo "== Priority autoscaling target"
aws application-autoscaling describe-scalable-targets --service-namespace ecs --region "$REGION" \
  --resource-ids service/sdr/priority --query 'ScalableTargets[].{min:MinCapacity,max:MaxCapacity}' --output table

echo "== Alarms"
aws cloudwatch describe-alarms --alarm-names sdr-priority-incoming-high sdr-priority-idle --region "$REGION" \
  --query 'MetricAlarms[].{alarm:AlarmName,state:StateValue,since:StateUpdatedTimestamp}' --output table

echo "== Recent scaling activity"
aws application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id service/sdr/priority \
  --region "$REGION" --max-results 5 --query 'ScalingActivities[].{time:StartTime,cause:Cause,status:StatusCode}' --output table
