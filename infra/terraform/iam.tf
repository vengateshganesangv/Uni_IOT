data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Pulls images, writes logs, reads the HiveMQ credentials at container start.
resource "aws_iam_role" "execution" {
  name               = "${var.project}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_ssm" {
  statement {
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.hivemq_mqtt_url.arn]
  }
}

resource "aws_iam_role_policy" "execution_ssm" {
  name   = "read-hivemq-credentials"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_ssm.json
}

# Only Emergency needs an application role: it calls PutMetricData (emergency_service.js:42-67).
resource "aws_iam_role" "emergency_task" {
  name               = "${var.project}-emergency-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "emergency_metrics" {
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["SmartDisasterRelief"]
    }
  }
}

resource "aws_iam_role_policy" "emergency_metrics" {
  name   = "put-workload-metric"
  role   = aws_iam_role.emergency_task.id
  policy = data.aws_iam_policy_document.emergency_metrics.json
}

# The services connect using a single MQTT_URL (mqtt.js parses "mqtts://user:pass@host:port" itself -
# verified directly against the installed mqtt package: connect() correctly extracts options.username/
# options.password from a URL in this form). Stored combined, as one SSM SecureString (free, unlike Secrets
# Manager), so only one secret needs wiring into each task instead of assembling it from two. NOTE: the
# value is also stored in Terraform state, so keep the state file private (it is git-ignored).
#
# With use_test_broker this parameter is never read (ecs.tf sets MQTT_URL as a plain env var instead, since
# the test broker allows anonymous connections), but SSM rejects an empty value, so a placeholder is stored.
resource "aws_ssm_parameter" "hivemq_mqtt_url" {
  name = "/${var.project}/hivemq/mqtt_url"
  type = "SecureString"
  value = (
    var.use_test_broker
    ? "unused"
    : "mqtts://${var.hivemq_username}:${var.hivemq_password}@${local.broker_host}:8883"
  )

  lifecycle {
    precondition {
      condition     = var.use_test_broker || (var.hivemq_username != "" && var.hivemq_password != "")
      error_message = "hivemq_username and hivemq_password are required unless use_test_broker = true."
    }
  }
}
