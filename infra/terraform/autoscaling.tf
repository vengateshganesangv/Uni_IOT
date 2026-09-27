# Priority Service autoscaling: step scaling on the custom metric the app already emits
# (SmartDisasterRelief/IncomingRequests, 1-second resolution, emergency_service.js:42-67).
#
# Why step scaling and not target tracking: IncomingRequests is total injected work, it does not fall as
# tasks are added, so it cannot be tracked to a per-task target without metric math + Container Insights.
# The steps mirror the code's own request tiers (5k/10k/20k/50k/100k per zone).
#
# Known limitation: the metric is emitted AFTER the burst is enqueued (the publish loop is synchronous) and
# a burst drains in seconds, so reactive scale-out often lands after the burst. Use priority_min_capacity
# as the warm floor for max-size events.

resource "aws_appautoscaling_target" "priority" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.priority.name}"
  min_capacity       = var.priority_min_capacity
  max_capacity       = var.priority_max_capacity
}

locals {
  scale_out_threshold = var.scale_steps[0].lower
}

# ---------------- scale OUT ----------------
resource "aws_appautoscaling_policy" "priority_out" {
  name               = "${var.project}-priority-scale-out"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.priority.service_namespace
  scalable_dimension = aws_appautoscaling_target.priority.scalable_dimension
  resource_id        = aws_appautoscaling_target.priority.resource_id

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = var.scale_out_cooldown
    metric_aggregation_type = "Maximum"

    dynamic "step_adjustment" {
      for_each = var.scale_steps
      content {
        # bounds are relative to the alarm threshold
        metric_interval_lower_bound = tostring(step_adjustment.value.lower - local.scale_out_threshold)
        metric_interval_upper_bound = step_adjustment.key + 1 < length(var.scale_steps) ? tostring(var.scale_steps[step_adjustment.key + 1].lower - local.scale_out_threshold) : null
        scaling_adjustment          = step_adjustment.value.add
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "priority_out" {
  alarm_name          = "${var.project}-priority-incoming-high"
  alarm_description   = "Sum(IncomingRequests) per 10s >= ${local.scale_out_threshold}: add Priority Service tasks"
  namespace           = "SmartDisasterRelief"
  metric_name         = "IncomingRequests"
  statistic           = "Sum"
  period              = 10 # allowed because the metric is published with StorageResolution=1
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = local.scale_out_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_appautoscaling_policy.priority_out.arn]
}

# ---------------- scale IN (slow: QoS0 + no SIGTERM handling means removing a task can drop in-flight messages) ----------------
resource "aws_appautoscaling_policy" "priority_in" {
  name               = "${var.project}-priority-scale-in"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.priority.service_namespace
  scalable_dimension = aws_appautoscaling_target.priority.scalable_dimension
  resource_id        = aws_appautoscaling_target.priority.resource_id

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = var.scale_in_cooldown
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = "0"
      scaling_adjustment          = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "priority_in" {
  alarm_name          = "${var.project}-priority-idle"
  alarm_description   = "No IncomingRequests for ${var.scale_in_idle_minutes} minutes: remove Priority Service tasks one at a time"
  namespace           = "SmartDisasterRelief"
  metric_name         = "IncomingRequests"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = var.scale_in_idle_minutes
  datapoints_to_alarm = var.scale_in_idle_minutes
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # no datapoints at all = idle
  alarm_actions       = [aws_appautoscaling_policy.priority_in.arn]
}
