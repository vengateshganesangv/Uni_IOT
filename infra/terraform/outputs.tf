output "region" {
  value = var.region
}

output "emergency_url" {
  description = "Base URL for scripts/fire-event.js. Empty when enable_alb = false: use scripts/aws-url.sh (task public IP)."
  value       = var.enable_alb ? "http://${aws_lb.emergency[0].dns_name}" : ""
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.svc : k => r.repository_url }
}

output "log_groups" {
  value = { for k, g in aws_cloudwatch_log_group.svc : k => g.name }
}

output "priority_capacity" {
  value = {
    min = var.priority_min_capacity
    max = var.priority_max_capacity
  }
}

output "mode" {
  value = {
    test_broker = var.use_test_broker
    spot        = var.use_fargate_spot
    alb         = var.enable_alb
  }
}
