# tasks.tf

# =========================================================
# ECS Task Definition + Service
#
# 패턴: sidecar (NGINX + FastAPI 동일 Task)
#   - network_mode = "awsvpc" → 동일 Task 내 컨테이너가 localhost 공유
#   - NGINX(port 80) → localhost:8000 → FastAPI
#
# Task 1개:
#   - hospital-task : nginx + api (staff/patient/portal 전체 서빙)
# =========================================================

locals {
  ecr_base = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"

  nginx_secrets = [
    { name = "API_KEY", valueFrom = data.tfe_outputs.secrets.values.api_key_secret_arn },
  ]

  hospital_secrets = [
    { name = "DATABASE_URL",        valueFrom = data.tfe_outputs.secrets.values.db_url_patient_secret_arn },
    { name = "JWT_SECRET",          valueFrom = "${data.tfe_outputs.secrets.values.jwt_secret_arn}::AWSCURRENT:" },
    { name = "JWT_SECRET_PREVIOUS", valueFrom = "${data.tfe_outputs.secrets.values.jwt_secret_arn}::AWSPREVIOUS:" },
    { name = "API_KEY",             valueFrom = data.tfe_outputs.secrets.values.api_key_secret_arn },
  ]
}


# ─────────────────────────────────────────────────────────
# CloudWatch Log Group
# ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "hospital" {
  name              = "/ecs/hospital"
  retention_in_days = 90
}


# ─────────────────────────────────────────────────────────
# Task Definition — 통합 병원 (nginx + api)
# nginx: staff/patient/portal 전체 서빙 (server_name 분기)
# api:   app/combined/backend (FastAPI, port 8000)
# CI/CD가 이미지 태그를 교체하므로 :latest는 초기값
# ─────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "hospital" {
  family                   = "hospital-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  cpu                      = "512"   # t3.medium 1대에 태스크 2개 수용 가능하도록 축소 김다정 20260604
  memory                   = "1536"  # t3.medium 1대에 태스크 2개 수용 가능하도록 축소 김다정 20260604

  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = "${local.ecr_base}/aws-hospital-nginx:latest"
      essential = true
      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]
      secrets = local.nginx_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/hospital"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "nginx"
        }
      }
      dependsOn = [{
        containerName = "api"
        condition     = "START"
      }]
    },
    {
      name      = "api"
      image     = "${local.ecr_base}/aws-hospital-api:latest"
      essential = true
      portMappings = [{
        containerPort = 8000
        protocol      = "tcp"
      }]
      environment = [
        { name = "COOKIE_SECURE",   value = "true" },
        { name = "ALLOWED_HOSTS",   value = "staff.mzclinic.cloud,patient.mzclinic.cloud,portal.mzclinic.cloud,localhost" },
        { name = "ALLOWED_ORIGINS", value = "https://staff.mzclinic.cloud,https://patient.mzclinic.cloud,https://portal.mzclinic.cloud" },
        { name = "TZ",              value = "Asia/Seoul" },
      ]
      secrets = local.hospital_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/hospital"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])
}


# ─────────────────────────────────────────────────────────
# ECS Service — 통합 병원
# 테스트 단계: ALB 없이 실행 (Task 정상 기동 확인 후 ALB 연결)
# ALB 연결 시: load_balancer 블록 추가 + deployment_minimum_healthy_percent = 100
# ─────────────────────────────────────────────────────────
resource "aws_ecs_service" "hospital" {
  name            = "hospital-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.hospital.arn
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

  # ALB 연결 by 김다정 20260604
  load_balancer {
    target_group_arn = data.aws_lb_target_group.hospital.arn
    container_name   = "nginx"
    container_port   = 80
  }

  deployment_minimum_healthy_percent = 100 # 변경: 0 → 100 (ALB 연결로 rolling update 보장) by 김다정 20260604
  deployment_maximum_percent         = 200
  availability_zone_rebalancing      = "DISABLED"

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main]
}
