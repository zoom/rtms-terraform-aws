data "aws_region" "current" {}

# ECS cluster ----------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
    base              = 0
  }
}

# CloudWatch logs ------------------------------------------------------------

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/ecs/${var.project_name}-worker"
  retention_in_days = var.log_retention_days
}

# IAM: task execution role (pulls image, reads secrets, writes logs) ---------

resource "aws_iam_role" "task_execution" {
  name = "${var.project_name}-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "secrets-read"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = [
        var.zm_rtms_client_secret_arn,
        var.zm_rtms_secret_secret_arn,
        var.zm_rtms_webhook_secret_secret_arn,
      ]
    }]
  })
}

# IAM: task role (what the app code does at runtime) -------------------------

resource "aws_iam_role" "task" {
  name = "${var.project_name}-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "task_s3_write" {
  name = "transcript-write"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${var.transcript_bucket_arn}/transcripts/*"
    }]
  })
}

# Allow ECS Exec for debugging into running tasks
resource "aws_iam_role_policy" "task_exec" {
  name = "ecs-exec"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

# Task definition ------------------------------------------------------------

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project_name}-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "rtms-worker"
    image     = var.worker_image
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [
      { name = "TRANSCRIPT_BACKEND", value = "s3" },
      { name = "TRANSCRIPT_BUCKET", value = var.transcript_bucket },
      { name = "AWS_REGION", value = data.aws_region.current.name },
      { name = "ZM_RTMS_HOST", value = var.zoom_host },
      { name = "EVENTLOOP_THREADS", value = tostring(var.eventloop_threads) },
      { name = "CALLBACK_EXECUTOR_WORKERS", value = tostring(var.callback_executor_workers) },
      { name = "TRANSCRIPT_FLUSH_INTERVAL", value = tostring(var.transcript_flush_interval) },
      { name = "LOG_LEVEL", value = var.log_level },
      # SDK-internal logging — JSON so CloudWatch Logs Insights can parse it
      { name = "ZM_RTMS_LOG_FORMAT", value = "json" },
      { name = "ZM_RTMS_LOG_LEVEL", value = "info" },
      { name = "ZM_RTMS_LOG_ENABLED", value = "true" },
    ]

    secrets = [
      { name = "ZM_RTMS_CLIENT", valueFrom = var.zm_rtms_client_secret_arn },
      { name = "ZM_RTMS_SECRET", valueFrom = var.zm_rtms_secret_secret_arn },
      { name = "ZM_RTMS_WEBHOOK_SECRET", valueFrom = var.zm_rtms_webhook_secret_secret_arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.worker.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "ecs"
      }
    }

    # Fargate respects this stop signal — gives our SIGTERM handler 30s to drain
    stopTimeout = 30
  }])
}

# Service --------------------------------------------------------------------

resource "aws_ecs_service" "worker" {
  name            = "${var.project_name}-worker"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.min_capacity

  enable_execute_command = true

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = var.spot_weight
    base              = 0
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.ondemand_weight > 0 ? [1] : []
    content {
      capacity_provider = "FARGATE"
      weight            = var.ondemand_weight
      base              = 1
    }
  }

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [var.worker_security_group_id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "rtms-worker"
    container_port   = 8080
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    # Let the autoscaler manage desired_count post-create
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_iam_role_policy.task_execution_secrets,
    aws_iam_role_policy.task_s3_write,
    aws_ecs_cluster_capacity_providers.this,
  ]
}

# Autoscaling ----------------------------------------------------------------

resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
}

resource "aws_appautoscaling_policy" "worker_cpu" {
  name               = "${var.project_name}-worker-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.worker.service_namespace
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_utilization
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
