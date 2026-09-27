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
    resources = [aws_ssm_parameter.hivemq_username.arn, aws_ssm_parameter.hivemq_password.arn]
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

# HiveMQ credentials live in SSM SecureString (free, unlike Secrets Manager). NOTE: the values are also
# stored in Terraform state, so keep the state file private (it is git-ignored).
#
# With use_test_broker the credentials are ignored by the broker (anonymous allowed) but the services still
# read the env vars, so a placeholder is stored (SSM rejects empty values).
resource "aws_ssm_parameter" "hivemq_username" {
  name  = "/${var.project}/hivemq/username"
  type  = "SecureString"
  value = var.hivemq_username != "" ? var.hivemq_username : "unused"

  lifecycle {
    precondition {
      condition     = var.use_test_broker || var.hivemq_username != ""
      error_message = "hivemq_username is required unless use_test_broker = true."
    }
  }
}

resource "aws_ssm_parameter" "hivemq_password" {
  name  = "/${var.project}/hivemq/password"
  type  = "SecureString"
  value = var.hivemq_password != "" ? var.hivemq_password : "unused"

  lifecycle {
    precondition {
      condition     = var.use_test_broker || var.hivemq_password != ""
      error_message = "hivemq_password is required unless use_test_broker = true."
    }
  }
}
