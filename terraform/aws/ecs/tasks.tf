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

# ─────────────────────────────────────────────────────────
# ECR 최신 이미지 자동 조회 (하드코딩 불필요)
# ─────────────────────────────────────────────────────────
data "aws_ecr_image" "nginx_patient" {
  repository_name = "aws-hospital-nginx-patient"
  most_recent     = true
}

data "aws_ecr_image" "api_patient" {
  repository_name = "aws-hospital-api-patient"
  most_recent     = true
}

data "aws_ecr_image" "nginx_staff" {
  repository_name = "aws-hospital-nginx-staff"
  most_recent     = true
}

data "aws_ecr_image" "api_staff" {
  repository_name = "aws-hospital-api-staff"
  most_recent     = true
}


locals {
  # FastAPI 공통 secrets (Secrets Manager → 컨테이너 환경변수)
  api_secrets = [
    { name = "DATABASE_URL", valueFrom = data.aws_secretsmanager_secret.db_url.arn     },
    { name = "JWT_SECRET",   valueFrom = data.aws_secretsmanager_secret.jwt_secret.arn },
    { name = "API_KEY",      valueFrom = data.aws_secretsmanager_secret.api_key.arn    },
  ]
  # NGINX secrets — envsubst로 nginx.conf에 API_KEY 주입 (프론트엔드 노출 방지)
  nginx_secrets = [
    { name = "API_KEY", valueFrom = data.aws_secretsmanager_secret.api_key.arn },
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
  cpu                      = "512"
  memory                   = "1536"

  container_definitions = jsonencode([
    {
      name      = "nginx-patient"
      image     = data.aws_ecr_image.nginx_patient.image_uri
      essential = true
      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]
      secrets = local.nginx_secrets
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
      image     = data.aws_ecr_image.api_patient.image_uri
      essential = true
      portMappings = [{
        containerPort = 8000
        protocol      = "tcp"
      }]
      environment = [
        { name = "COOKIE_SECURE",    value = "true"                    },
        { name = "ALLOWED_HOSTS",    value = var.patient_allowed_hosts },
        { name = "ALLOWED_ORIGINS",  value = "https://${var.patient_allowed_hosts}" },
        { name = "TZ",               value = "Asia/Seoul"              },
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
  cpu                      = "512"
  memory                   = "1536"

  container_definitions = jsonencode([
    {
      name      = "nginx-staff"
      image     = data.aws_ecr_image.nginx_staff.image_uri
      essential = true
      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]
      secrets = local.nginx_secrets
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
      image     = data.aws_ecr_image.api_staff.image_uri
      essential = true
      portMappings = [{
        containerPort = 8000
        protocol      = "tcp"
      }]
      environment = [
        { name = "COOKIE_SECURE",   value = "true"                   },
        { name = "ALLOWED_HOSTS",   value = var.staff_allowed_hosts  },
        { name = "ALLOWED_ORIGINS", value = "https://${var.staff_allowed_hosts}" },
        { name = "TZ",              value = "Asia/Seoul"             },
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
# ─────────────────────────────────────────────────────────
resource "aws_ecs_service" "patient" {
  name            = "patient-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.patient.arn
  desired_count   = 1


  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = data.aws_subnets.app.ids
    security_groups  = [aws_security_group.ecs_ec2.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = data.aws_lb_target_group.patient.arn
    container_name   = "nginx-patient"
    container_port   = 80
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 100
  availability_zone_rebalancing      = "DISABLED"

  lifecycle {
    # desired_count: 오토스케일링이 변경하므로 Terraform이 덮어쓰지 않음
    # task_definition: CI/CD(GitHub Actions)가 관리하므로 Terraform이 덮어쓰지 않음
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main]
}


# ─────────────────────────────────────────────────────────
# ECS Service — 의료진 포털
# ─────────────────────────────────────────────────────────
resource "aws_ecs_service" "staff" {
  name            = "staff-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.staff.arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = data.aws_subnets.app.ids
    security_groups  = [aws_security_group.ecs_ec2.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = data.aws_lb_target_group.staff.arn
    container_name   = "nginx-staff"
    container_port   = 80
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 100
  availability_zone_rebalancing      = "DISABLED"

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main]
}


# ─────────────────────────────────────────────────────────
# ECS Service Auto Scaling — 환자 포털 (CPU 70% 기준)
# EC2 1대 기준: Task 512 CPU × 4개 수용 가능 (2048 CPU)
# min:1 → max:4, EC2 용량 초과 시 Capacity Provider가 EC2 추가
# ─────────────────────────────────────────────────────────
resource "aws_appautoscaling_target" "patient" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/patient-service"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.patient]
}

resource "aws_appautoscaling_policy" "patient_cpu" {
  name               = "patient-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.patient.resource_id
  scalable_dimension = aws_appautoscaling_target.patient.scalable_dimension
  service_namespace  = aws_appautoscaling_target.patient.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}


# ─────────────────────────────────────────────────────────
# ECS Service Auto Scaling — 의료진 포털 (CPU 70% 기준)
# EC2 1대 기준: Task 512 CPU × 4개 수용 가능 (2048 CPU)
# min:1 → max:4, EC2 용량 초과 시 Capacity Provider가 EC2 추가
# ─────────────────────────────────────────────────────────
resource "aws_appautoscaling_target" "staff" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/staff-service"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.staff]
}

resource "aws_appautoscaling_policy" "staff_cpu" {
  name               = "staff-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.staff.resource_id
  scalable_dimension = aws_appautoscaling_target.staff.scalable_dimension
  service_namespace  = aws_appautoscaling_target.staff.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
