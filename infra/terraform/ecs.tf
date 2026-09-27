resource "aws_ecs_cluster" "main" {
  name = var.project

  setting {
    name  = "containerInsights"
    value = "disabled" # step scaling on IncomingRequests does not need per-task Insights metrics (cost)
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

locals {
  image = { for s in local.services : s => "${aws_ecr_repository.svc[s].repository_url}:${var.image_tag}" }

  # Credentials are injected as env vars; the (unmodified) services already read them via process.env / dotenv.
  hivemq_secrets = [
    { name = "HIVEMQ_USERNAME", valueFrom = aws_ssm_parameter.hivemq_username.arn },
    { name = "HIVEMQ_PASSWORD", valueFrom = aws_ssm_parameter.hivemq_password.arn },
  ]

  task_cfg = {
    emergency = { cpu = var.emergency_cpu, memory = var.emergency_memory, port = 3001, entry = "emergency_service.js" }
    priority  = { cpu = var.priority_cpu, memory = var.priority_memory, port = null, entry = "Priority_Service.js" }
    rescue    = { cpu = var.rescue_cpu, memory = var.rescue_memory, port = null, entry = "rescue_service.js" }
  }

  # Test broker only: node cannot read a CA from an env var, so write it to a file first, then exec node.
  # (Node then trusts the throwaway CA; the app code and Dockerfiles are unchanged.)
  test_ca_env = [
    { name = "NODE_EXTRA_CA_CERTS", value = "/tmp/ca.crt" },
    { name = "TEST_CA_PEM", value = var.use_test_broker ? tls_self_signed_cert.ca[0].cert_pem : "" },
  ]

  stateless_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
}

resource "aws_cloudwatch_log_group" "svc" {
  for_each          = toset(local.services)
  name              = "/ecs/${var.project}/${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "svc" {
  for_each                 = local.task_cfg
  family                   = "${var.project}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = each.key == "emergency" ? aws_iam_role.emergency_task.arn : null

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = each.key
      image        = local.image[each.key]
      essential    = true
      stopTimeout  = 30
      secrets      = local.hivemq_secrets
      portMappings = each.value.port == null ? [] : [{ containerPort = each.value.port, protocol = "tcp" }]

      environment = var.use_test_broker ? local.test_ca_env : []
      command = var.use_test_broker ? [
        "sh", "-c", "printf '%s\\n' \"$TEST_CA_PEM\" > /tmp/ca.crt && exec node ${each.value.entry}"
      ] : ["node", each.value.entry] # same as the Dockerfile CMD

      # PID 1 reaper so Node receives SIGTERM on scale-in / deploys
      linuxParameters = { initProcessEnabled = true }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.svc[each.key].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = each.key
        }
      }
    }
  ])
}

# ---- Emergency Request Service: stateless load generator, fixed size ----
resource "aws_ecs_service" "emergency" {
  name                              = "emergency"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.svc["emergency"].arn
  desired_count                     = var.emergency_desired_count
  health_check_grace_period_seconds = var.enable_alb ? 60 : null

  capacity_provider_strategy {
    capacity_provider = local.stateless_provider
    weight            = 1
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.emergency.id]
    assign_public_ip = true
  }

  dynamic "load_balancer" {
    for_each = var.enable_alb ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.emergency[0].arn
      container_name   = "emergency"
      container_port   = 3001
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  depends_on = [aws_lb_listener.http, aws_ecs_cluster_capacity_providers.main, aws_ecs_service.broker]
}

# ---- Priority Service: the only horizontally scalable component (MQTT shared subscription) ----
resource "aws_ecs_service" "priority" {
  name            = "priority"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.svc["priority"].arn
  desired_count   = var.priority_min_capacity

  capacity_provider_strategy {
    capacity_provider = local.stateless_provider
    weight            = 1
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.workers.id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  lifecycle {
    ignore_changes = [desired_count] # owned by Application Auto Scaling
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main, aws_ecs_service.broker]
}

# ---- Rescue Service: stateful singleton, always on-demand. Exactly one task, never two at once ----
resource "aws_ecs_service" "rescue" {
  name                               = "rescue"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.svc["rescue"].arn
  desired_count                      = 1
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.workers.id]
    assign_public_ip = true
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  depends_on = [aws_ecs_service.broker]
}
