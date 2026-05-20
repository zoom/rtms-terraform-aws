resource "aws_lb" "this" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true
  enable_http2               = true

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "worker" {
  name        = "${var.project_name}-worker-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 30

  # ALB matcher max is 499. The worker's main.py monkey-patches the SDK's
  # WebhookHandler.do_GET to return 200 (the SDK only natively implements
  # do_POST, which would otherwise yield 501 → out of range).
  health_check {
    enabled             = true
    path                = "/"
    matcher             = "200-299"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project_name}-worker-tg" }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.worker.arn
  }
}

# Port 80 listener — issues a 301 to the equivalent https:// URL.
# Misconfigured callers (http:// instead of https://) get a loud redirect
# rather than a connection refused. We never forward HTTP to the worker.
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}
