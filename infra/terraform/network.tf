data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Public subnets + public IPs on tasks avoid NAT gateway cost (tasks must reach the external HiveMQ
# broker, CloudWatch, ECR and Logs). Tasks are protected by security groups: the only inbound path is
# ALB -> Emergency on 3001.
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "alb" {
  count       = var.enable_alb ? 1 : 0
  name        = "${var.project}-alb"
  description = "ALB in front of Emergency Request Service"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from allowed CIDR only"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "emergency" {
  name        = "${var.project}-emergency"
  description = "Emergency Request Service tasks"
  vpc_id      = aws_vpc.main.id

  # With an ALB: only the ALB may reach the task. Without: only allowed_cidr may reach the task's public IP.
  dynamic "ingress" {
    for_each = var.enable_alb ? [1] : []
    content {
      description     = "From ALB"
      from_port       = 3001
      to_port         = 3001
      protocol        = "tcp"
      security_groups = [aws_security_group.alb[0].id]
    }
  }

  dynamic "ingress" {
    for_each = var.enable_alb ? [] : [1]
    content {
      description = "Direct access from allowed CIDR only"
      from_port   = 3001
      to_port     = 3001
      protocol    = "tcp"
      cidr_blocks = [var.allowed_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Priority and Rescue only make outbound connections (broker, ECR, logs): no inbound at all.
resource "aws_security_group" "workers" {
  name        = "${var.project}-workers"
  description = "Priority and Rescue tasks (egress only)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
