# ===========================================================================================================
# OPTIONAL TEST BROKER  (var.use_test_broker, default false). Not part of the real system.
#
# The four services hard-code the HiveMQ hostname. To test without a HiveMQ account (and without touching
# the app code) this file:
#   1. runs Mosquitto (TLS 8883) on Fargate,
#   2. registers it in a Cloud Map PRIVATE DNS namespace named "s1.eu.hivemq.cloud" under the service name
#      "1490e7aa...": inside this VPC the hard-coded hostname now resolves to the broker's private IP,
#   3. issues a throwaway CA + server certificate whose SAN is that hostname; the services trust the CA via
#      NODE_EXTRA_CA_CERTS (see ecs.tf).
# Only tasks in this VPC are affected; nothing outside the VPC (including the real HiveMQ) is touched.
# Broker behaviour is Mosquitto's (single-threaded), NOT HiveMQ's.
# ===========================================================================================================

locals {
  # Must equal the host in every mqtt.connect() call in the services.
  broker_host         = "1490e7aa531c43e6af66775dcb39171b.s1.eu.hivemq.cloud"
  broker_service_name = split(".", local.broker_host)[0]
  broker_namespace    = join(".", slice(split(".", local.broker_host), 1, length(split(".", local.broker_host))))
}

# ---- throwaway TLS material (private keys end up in Terraform state: test use only) ----
resource "tls_private_key" "ca" {
  count     = var.use_test_broker ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  count                 = var.use_test_broker ? 1 : 0
  private_key_pem       = tls_private_key.ca[0].private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 72
  allowed_uses          = ["cert_signing", "crl_signing"]

  subject {
    common_name = "sdr-test-ca"
  }
}

resource "tls_private_key" "server" {
  count     = var.use_test_broker ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server" {
  count           = var.use_test_broker ? 1 : 0
  private_key_pem = tls_private_key.server[0].private_key_pem
  dns_names       = [local.broker_host]

  subject {
    common_name = local.broker_host
  }
}

resource "tls_locally_signed_cert" "server" {
  count                 = var.use_test_broker ? 1 : 0
  cert_request_pem      = tls_cert_request.server[0].cert_request_pem
  ca_private_key_pem    = tls_private_key.ca[0].private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca[0].cert_pem
  validity_period_hours = 72
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

# Broker gets its key/cert through SSM (never in plain task-definition JSON). The CA certificate is public
# and is passed to the broker and workers as a plain env var.
resource "aws_ssm_parameter" "broker_server_key" {
  count = var.use_test_broker ? 1 : 0
  name  = "/${var.project}/testbroker/server_key"
  type  = "SecureString"
  value = tls_private_key.server[0].private_key_pem
}

resource "aws_ssm_parameter" "broker_server_crt" {
  count = var.use_test_broker ? 1 : 0
  name  = "/${var.project}/testbroker/server_crt"
  type  = "SecureString"
  value = tls_locally_signed_cert.server[0].cert_pem
}

data "aws_iam_policy_document" "broker_ssm" {
  count = var.use_test_broker ? 1 : 0
  statement {
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.broker_server_key[0].arn, aws_ssm_parameter.broker_server_crt[0].arn]
  }
}

resource "aws_iam_role_policy" "execution_broker_ssm" {
  count  = var.use_test_broker ? 1 : 0
  name   = "read-test-broker-cert"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.broker_ssm[0].json
}

# ---- private DNS: hard-coded hostname -> broker task ----
resource "aws_service_discovery_private_dns_namespace" "broker" {
  count = var.use_test_broker ? 1 : 0
  name  = local.broker_namespace
  vpc   = aws_vpc.main.id
}

resource "aws_service_discovery_service" "broker" {
  count = var.use_test_broker ? 1 : 0
  name  = local.broker_service_name

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.broker[0].id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {}
}

# ---- network: only the service tasks may reach the broker ----
resource "aws_security_group" "broker" {
  count       = var.use_test_broker ? 1 : 0
  name        = "${var.project}-test-broker"
  description = "Test MQTT broker (TLS 8883) reachable from service tasks only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MQTT over TLS from service tasks"
    from_port       = 8883
    to_port         = 8883
    protocol        = "tcp"
    security_groups = [aws_security_group.workers.id, aws_security_group.emergency.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---- the broker itself (on-demand: an interruption would drop every in-flight message) ----
resource "aws_ecs_task_definition" "broker" {
  count                    = var.use_test_broker ? 1 : 0
  family                   = "${var.project}-broker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.test_broker_cpu
  memory                   = var.test_broker_memory
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "broker"
      image        = local.image["broker"]
      essential    = true
      portMappings = [{ containerPort = 8883, protocol = "tcp" }]
      environment  = [{ name = "CA_CRT", value = tls_self_signed_cert.ca[0].cert_pem }]
      secrets = [
        { name = "SERVER_CRT", valueFrom = aws_ssm_parameter.broker_server_crt[0].arn },
        { name = "SERVER_KEY", valueFrom = aws_ssm_parameter.broker_server_key[0].arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.svc["broker"].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "broker"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "broker" {
  count                 = var.use_test_broker ? 1 : 0
  name                  = "broker"
  cluster               = aws_ecs_cluster.main.id
  task_definition       = aws_ecs_task_definition.broker[0].arn
  desired_count         = 1
  launch_type           = "FARGATE"
  wait_for_steady_state = true # workers are created only after the broker is up (they crash on connect errors)

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.broker[0].id]
    assign_public_ip = true # needed to pull the image without a NAT gateway; the security group blocks all outside access
  }

  service_registries {
    registry_arn = aws_service_discovery_service.broker[0].arn
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }
}
