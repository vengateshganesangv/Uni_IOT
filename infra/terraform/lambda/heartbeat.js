// Runs every minute via EventBridge. Publishes a real IncomingRequests=0 datapoint so the
// sdr-priority-idle CloudWatch alarm and its Step Scaling scale-in action always have an actual
// metric value to evaluate during quiet periods (Step Scaling cannot act on "no data at all" -
// see infra/terraform/autoscaling.tf and docs/CLAUDE_INVESTIGATION_LOG.md Session 4).
// Must match the real metric exactly: same namespace/name/no dimensions/storage resolution as
// Emergency_Request_Service's own PutMetricData call (emergency_service.js:42-67).
const { CloudWatchClient, PutMetricDataCommand } = require("@aws-sdk/client-cloudwatch");

const cloudwatch = new CloudWatchClient({});

exports.handler = async () => {
  await cloudwatch.send(
    new PutMetricDataCommand({
      Namespace: "SmartDisasterRelief",
      MetricData: [
        {
          MetricName: "IncomingRequests",
          Value: 0,
          Unit: "Count",
          StorageResolution: 1,
        },
      ],
    })
  );
  return { ok: true };
};
