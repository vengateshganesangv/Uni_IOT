# Optional (var.enable_alb, default false): an ALB is ~US$0.035/h fixed even when idle.
resource "aws_lb" "emergency" {
  count              = var.enable_alb ? 1 : 0
  name               = "${var.project}-emergency"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb[0].id]
  idle_timeout       = 120 # POST /emergency replies only after publishing up to 100k messages
}

resource "aws_lb_target_group" "emergency" {
  count                = var.enable_alb ? 1 : 0
  name                 = "${var.project}-emergency"
  port                 = 3001
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 15

  # The app has no health route; Express answers 404 on "/", which still proves the process is serving.
  health_check {
    path                = "/"
    matcher             = "200-404"
    interval            = 15
    timeout             = 10 # the event loop is blocked ~0.5s per 100k messages during a burst
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

resource "aws_lb_listener" "http" {
  count             = var.enable_alb ? 1 : 0
  load_balancer_arn = aws_lb.emergency[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.emergency[0].arn
  }
}
