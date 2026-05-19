# =========================================================
# ECS Task Definitions + Services
#
# 패턴: sidecar (NGINX + FastAPI 동일 Task)
#   - network_mode = "awsvpc" → 동일 Task 내 컨테이너가 localhost 공유
#   - NGINX(port 80) → localhost:8000 → FastAPI
#
# Task 2개:
#   - patient-task : nginx-patient + api-patient
#   - staff-task   : nginx-staff  + api-staff
#
# ECS Service 2개 (ALB Target Group ARN이 입력된 경우에만 생성):
#   - patient-service (Public ALB)
#   - staff-service   (Internal ALB)
# =========================================================

locals {
  # FastAPI 공통 secrets (Secrets Manager → 컨테이너 환경변수)
  api_secrets = [
    { name = "DATABASE_URL", valueFrom = var.secret_db_url_arn },
    { name = "JWT_SECRET",   valueFrom = var.secret_jwt_arn    },
    { name = "API_KEY",      valueFrom = var.secret_api_key_arn },
  ]
}


# ─────────────────────────────────────────────────────────
# CloudWatch Log Groups
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "patient" {
  name              = "/ecs/patient"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "staff" {
  name              = "/ecs/staff"
  retention_in_days = 90
}


# ─────────────────────────────────────────────────────────
# Task Definition — 환자 포털 (nginx-patient + api-patient)
# ─────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "patient" {
  family                   = "patient-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  cpu                      = "1024"
  memory                   = "1536"

  container_definitions = jsonencode([
    {
      name      = "nginx-patient"
      image     = var.nginx_patient_image
      essential = true
      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.patient.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "nginx"
        }
      }
      dependsOn = [{
        containerName = "api-patient"
        condition     = "START"
      }]
    },
    {
      name      = "api-patient"
      image     = var.api_patient_image
      essential = true
      portMappings = [{
        containerPort = 8000
        protocol      = "tcp"
      }]
      environment = [
        { name = "COOKIE_SECURE",    value = "true"                    },
        { name = "ALLOWED_HOSTS",    value = var.patient_allowed_hosts },
        { name = "ALLOWED_ORIGINS",  value = "https://${var.patient_allowed_hosts}" },
      ]
      secrets = local.api_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.patient.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "api"
        }
      }
    }
  ])
}


# ─────────────────────────────────────────────────────────
# Task Definition — 의료진 포털 (nginx-staff + api-staff)
# ─────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "staff" {
  family                   = "staff-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  cpu                      = "1024"
  memory                   = "1536"

  container_definitions = jsonencode([
    {
      name      = "nginx-staff"
      image     = var.nginx_staff_image
      essential = true
      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.staff.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "nginx"
        }
      }
      dependsOn = [{
        containerName = "api-staff"
        condition     = "START"
      }]
    },
    {
      name      = "api-staff"
      image     = var.api_staff_image
      essential = true
      portMappings = [{
        containerPort = 8000
        protocol      = "tcp"
      }]
      environment = [
        { name = "COOKIE_SECURE",   value = "true"                   },
        { name = "ALLOWED_HOSTS",   value = var.staff_allowed_hosts  },
        { name = "ALLOWED_ORIGINS", value = "https://${var.staff_allowed_hosts}" },
      ]
      secrets = local.api_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.staff.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "api"
        }
      }
    }
  ])
}


# ─────────────────────────────────────────────────────────
# ECS Service — 환자 포털
# patient_tg_arn 이 입력된 경우에만 생성 (ALB apply 이후)
# ─────────────────────────────────────────────────────────
resource "aws_ecs_service" "patient" {
  count = var.patient_tg_arn != "" ? 1 : 0

  name            = "patient-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.patient.arn
  desired_count   = 3   # 3 AZ × 1 Task

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [aws_security_group.ecs_ec2.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.patient_tg_arn
    container_name   = "nginx-patient"
    container_port   = 80
  }

  # 롤링 업데이트: 최소 1 Task 유지, 최대 200% 배포
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  # ECS Service Auto Scaling (CPU 70% 기준)
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main]
}


# ─────────────────────────────────────────────────────────
# ECS Service — 의료진 포털
# ─────────────────────────────────────────────────────────
resource "aws_ecs_service" "staff" {
  count = var.staff_tg_arn != "" ? 1 : 0

  name            = "staff-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.staff.arn
  desired_count   = 3

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [aws_security_group.ecs_ec2.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.staff_tg_arn
    container_name   = "nginx-staff"
    container_port   = 80
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main]
}


# ─────────────────────────────────────────────────────────
# ECS Service Auto Scaling — 환자 포털 (CPU 70% 기준)
# ─────────────────────────────────────────────────────────
resource "aws_appautoscaling_target" "patient" {
  count = var.patient_tg_arn != "" ? 1 : 0

  max_capacity       = 9
  min_capacity       = 3
  resource_id        = "service/${aws_ecs_cluster.main.name}/patient-service"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.patient]
}

resource "aws_appautoscaling_policy" "patient_cpu" {
  count = var.patient_tg_arn != "" ? 1 : 0

  name               = "patient-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.patient[0].resource_id
  scalable_dimension = aws_appautoscaling_target.patient[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.patient[0].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
