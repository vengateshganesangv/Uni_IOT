resource "aws_ecs_cluster" "main" {
  name = var.project

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

locals {
  image = {
    for s in local.services :
    s => "${aws_ecr_repository.svc[s].repository_url}:${var.image_tag}"
  }

  task_cfg = {
    emergency = {
      cpu    = var.emergency_cpu
      memory = var.emergency_memory
      port   = 3001
      entry  = "emergency_service.js"
    }

    priority = {
      cpu    = var.priority_cpu
      memory = var.priority_memory
      port   = null
      entry  = "Priority_Service.js"
    }

    rescue = {
      cpu    = var.rescue_cpu
      memory = var.rescue_memory
      port   = null
      entry  = "rescue_service.js"
    }
  }

  # CA used by the services when the AWS Mosquitto broker is enabled.
  test_ca_env = [
    {
      name  = "NODE_EXTRA_CA_CERTS"
      value = "/tmp/ca.crt"
    },
    {
      name  = "TEST_CA_PEM"
      value = var.use_test_broker ? tls_self_signed_cert.ca[0].cert_pem : ""
    }
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
      name        = each.key
      image       = local.image[each.key]
      essential   = true
      stopTimeout = 30

      portMappings = each.value.port == null ? [] : [
        {
          containerPort = each.value.port
          protocol      = "tcp"
        }
      ]

      # Test-broker mode: MQTT_URL is a plain env var (anonymous connection, no credentials, so nothing
      # sensitive) pointing at the AWS Mosquitto broker, plus the throwaway CA it needs to trust.
      # Real-HiveMQ mode: MQTT_URL instead comes from the `secrets` block below, since it embeds real
      # credentials (mqtts://user:pass@host:8883 - mqtt.js parses auth out of the URL itself).
      # Rescue additionally connects to the shared Redis service either way.
      environment = concat(
        var.use_test_broker ? local.test_ca_env : [],
        var.use_test_broker ? [
          {
            name  = "MQTT_URL"
            value = "mqtts://${local.broker_host}:8883"
          }
        ] : [],
        each.key == "rescue" ? [
          {
            name  = "REDIS_URL"
            value = "redis://redis.redis.local:6379"
          }
        ] : []
      )

      secrets = var.use_test_broker ? [] : [
        {
          name      = "MQTT_URL"
          valueFrom = aws_ssm_parameter.hivemq_mqtt_url.arn
        }
      ]

      command = var.use_test_broker ? [
        "sh",
        "-c",
        "printf '%s\\n' \"$TEST_CA_PEM\" > /tmp/ca.crt && exec node ${each.value.entry}"
        ] : [
        "node",
        each.value.entry
      ]

      linuxParameters = {
        initProcessEnabled = true
      }

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

# -------------------------------------------------------------------
# Emergency Request Service
# -------------------------------------------------------------------

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

  depends_on = [
    aws_lb_listener.http,
    aws_ecs_cluster_capacity_providers.main,
    aws_ecs_service.broker
  ]
}

# -------------------------------------------------------------------
# Priority Service
# MQTT shared subscription allows multiple Priority workers.
# Desired count is controlled by Application Auto Scaling.
# -------------------------------------------------------------------

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
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_ecs_service.broker
  ]
}

# -------------------------------------------------------------------
# Rescue Service
# Rescue now uses:
#   - MQTT shared subscription
#   - Redis shared state
#
# This allows multiple Rescue workers while keeping one shared pool
# of 50 simulated rescue teams.
# Desired count is controlled by Application Auto Scaling.
# -------------------------------------------------------------------

resource "aws_ecs_service" "rescue" {
  name            = "rescue"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.svc["rescue"].arn
  desired_count   = var.rescue_min_capacity

  launch_type = "FARGATE"

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
    # Application Auto Scaling owns the running Rescue task count.
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_ecs_service.broker,
    aws_ecs_service.redis
  ]
}