# ===========================================================================================================
# SCALE-IN FIX: a 1-minute heartbeat Lambda that publishes IncomingRequests=0.
#
# Bug this fixes (found on a real deployment, see docs/CLAUDE_INVESTIGATION_LOG.md Session 4): Emergency
# Request Service only publishes IncomingRequests when a real request happens, never a 0 during idle. The
# sdr-priority-idle alarm (autoscaling.tf) uses treat_missing_data=breaching, so it still correctly reaches
# ALARM state, but AWS Application Auto Scaling's Step Scaling policy has to read an actual metric datapoint
# to pick a step bracket, and with zero datapoints available it fails outright:
#   "Failed to execute AutoScaling action: Metric data points must be provided"
# Confirmed in AWS's own alarm history - this happened on every idle period, forever, with no fix possible
# by waiting longer. This heartbeat gives the metric a continuous stream of real (0-valued) datapoints during
# idle, so both the alarm and the Step Scaling evaluation have something real to act on.
#
# No application code touched: this is a separate, infrastructure-only Lambda.
# ===========================================================================================================

data "archive_file" "heartbeat" {
  type        = "zip"
  source_file = "${path.module}/lambda/heartbeat.js"
  output_path = "${path.module}/build/heartbeat.zip"
}

data "aws_iam_policy_document" "heartbeat_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "heartbeat" {
  name               = "${var.project}-heartbeat"
  assume_role_policy = data.aws_iam_policy_document.heartbeat_assume.json
}

resource "aws_iam_role_policy_attachment" "heartbeat_logs" {
  role       = aws_iam_role.heartbeat.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "heartbeat_metrics" {
  name   = "put-workload-metric"
  role   = aws_iam_role.heartbeat.id
  policy = data.aws_iam_policy_document.emergency_metrics.json # same scoped PutMetricData permission (iam.tf)
}

resource "aws_cloudwatch_log_group" "heartbeat" {
  name              = "/aws/lambda/${var.project}-priority-idle-heartbeat"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "heartbeat" {
  function_name    = "${var.project}-priority-idle-heartbeat"
  role             = aws_iam_role.heartbeat.arn
  handler          = "heartbeat.handler"
  runtime          = "nodejs20.x" # includes the AWS SDK v3 (@aws-sdk/client-cloudwatch) already - no dependencies to bundle
  timeout          = 10
  memory_size      = 128
  filename         = data.archive_file.heartbeat.output_path
  source_code_hash = data.archive_file.heartbeat.output_base64sha256

  depends_on = [aws_cloudwatch_log_group.heartbeat]
}

resource "aws_cloudwatch_event_rule" "heartbeat" {
  name                = "${var.project}-priority-idle-heartbeat"
  description         = "Every minute: publish IncomingRequests=0 so the idle/scale-in alarm always has real data"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "heartbeat" {
  rule = aws_cloudwatch_event_rule.heartbeat.name
  arn  = aws_lambda_function.heartbeat.arn
}

resource "aws_lambda_permission" "heartbeat_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.heartbeat.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.heartbeat.arn
}
