# =========================================================
# 멀티클라우드 비용 분석 RAG
# =========================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_region" "bedrock" {
  provider = aws.bedrock
}

# ---------------------------------------------------------
# OpenSearch Serverless — 벡터 스토어
# ---------------------------------------------------------
resource "aws_opensearchserverless_security_policy" "kb_encryption" {
  provider    = aws.bedrock
  name        = "aws-cost-kb"
  type        = "encryption"
  description = "Knowledge Base 벡터 스토어 암호화"

  policy = jsonencode({
    Rules = [{
      Resource     = ["collection/aws-cost-kb"]
      ResourceType = "collection"
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "kb_network" {
  provider    = aws.bedrock
  name        = "aws-cost-kb"
  type        = "network"
  description = "Knowledge Base 벡터 스토어 네트워크"

  policy = jsonencode([{
    Rules = [
      {
        Resource     = ["collection/aws-cost-kb"]
        ResourceType = "collection"
      },
      {
        Resource     = ["collection/aws-cost-kb"]
        ResourceType = "dashboard"
      },
    ]
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_access_policy" "kb" {
  provider    = aws.bedrock
  name        = "aws-cost-kb"
  type        = "data"
  description = "Bedrock KB → OpenSearch 접근 정책"

  policy = jsonencode([{
    Rules = [
      {
        Resource     = ["collection/aws-cost-kb"]
        Permission   = ["aoss:CreateCollectionItems", "aoss:DeleteCollectionItems", "aoss:UpdateCollectionItems", "aoss:DescribeCollectionItems"]
        ResourceType = "collection"
      },
      {
        Resource     = ["index/aws-cost-kb/*"]
        Permission   = ["aoss:CreateIndex", "aoss:DeleteIndex", "aoss:UpdateIndex", "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"]
        ResourceType = "index"
      },
    ]
    Principal = [
      aws_iam_role.bedrock_kb.arn,
    ]
  }])

  depends_on = [aws_iam_role.bedrock_kb]
}

resource "aws_opensearchserverless_collection" "kb" {
  provider    = aws.bedrock
  name        = "aws-cost-kb"
  type        = "VECTORSEARCH"
  description = "멀티클라우드 비용 벡터 스토어"
  tags        = local.common_tags

  depends_on = [
    aws_opensearchserverless_security_policy.kb_encryption,
    aws_opensearchserverless_security_policy.kb_network,
  ]
}

# ---------------------------------------------------------
# IAM — Bedrock Knowledge Base 역할
# ---------------------------------------------------------
resource "aws_iam_role" "bedrock_kb" {
  provider = aws.bedrock
  name     = "aws-cost-bedrock-kb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:bedrock:${data.aws_region.bedrock.name}:${data.aws_caller_identity.current.account_id}:knowledge-base/*"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "bedrock_kb" {
  provider = aws.bedrock
  name     = "aws-cost-bedrock-kb-policy"
  role     = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Read"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          data.terraform_remote_state.s3.outputs.storage_bucket_arn,
          "${data.terraform_remote_state.s3.outputs.storage_bucket_arn}/cost/chunks/*",
        ]
      },
      {
        Sid    = "BedrockEmbed"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${data.aws_region.bedrock.name}::foundation-model/amazon.titan-embed-text-v2:0"
      },
      {
        Sid    = "OpenSearch"
        Effect = "Allow"
        Action = ["aoss:APIAccessAll"]
        Resource = aws_opensearchserverless_collection.kb.arn
      },
    ]
  })
}

# ---------------------------------------------------------
# OpenSearch 인덱스 사전 생성 (Bedrock KB 생성 전에 필수)
# ---------------------------------------------------------
resource "null_resource" "opensearch_index" {
  provider = null

  depends_on = [
    aws_opensearchserverless_collection.kb,
    aws_opensearchserverless_access_policy.kb,
    aws_iam_role_policy.bedrock_kb,
  ]

  triggers = {
    collection_id = aws_opensearchserverless_collection.kb.id
  }

  provisioner "local-exec" {
    command = <<-EOF
python3 << 'PYEOF'
import boto3, json, time, urllib.request, urllib.error, ssl

region = "${var.bedrock_region}"
client  = boto3.client("opensearchserverless", region_name=region)

# 컬렉션이 ACTIVE 상태인지 확인 (AWS provider가 대기하지만 안전을 위해 재확인)
for i in range(20):
    r       = client.batch_get_collection(names=["aws-cost-kb"])
    details = r.get("collectionDetails", [])
    if details and details[0]["status"] == "ACTIVE":
        endpoint = details[0]["collectionEndpoint"]
        print(f"Collection ACTIVE: {endpoint}")
        break
    status = details[0]["status"] if details else "NOT_FOUND"
    print(f"Waiting for collection ({status})... [{i+1}/20]")
    time.sleep(30)
else:
    raise RuntimeError("Collection did not reach ACTIVE state")

from botocore.auth     import SigV4Auth
from botocore.awsrequest import AWSRequest

url  = f"{endpoint}/aws-cost-idx"
body = json.dumps({
    "settings": {"index.knn": True},
    "mappings": {
        "properties": {
            "embedding": {
                "type":      "knn_vector",
                "dimension": 1024,
                "method": {
                    "engine":     "faiss",
                    "space_type": "l2",
                    "name":       "hnsw"
                }
            },
            "text":     {"type": "text"},
            "metadata": {"type": "text"}
        }
    }
}).encode()

sess    = boto3.session.Session()
creds   = sess.get_credentials().get_frozen_credentials()
aws_req = AWSRequest(method="PUT", url=url, data=body,
                     headers={"Content-Type": "application/json"})
SigV4Auth(creds, "aoss", region).add_auth(aws_req)

req = urllib.request.Request(url, data=body, headers=dict(aws_req.headers), method="PUT")
try:
    with urllib.request.urlopen(req, context=ssl.create_default_context()) as resp:
        print("Index created:", resp.read().decode())
except urllib.error.HTTPError as e:
    err = e.read().decode()
    if "resource_already_exists_exception" in err:
        print("Index already exists, skipping")
    else:
        raise RuntimeError(f"Index creation failed [{e.code}]: {err}")
PYEOF
EOF
  }
}

# ---------------------------------------------------------
# Bedrock Knowledge Base
# ---------------------------------------------------------
resource "aws_bedrockagent_knowledge_base" "cost" {
  provider    = aws.bedrock
  name        = "aws-cost-bedrock-kb"
  description = "멀티클라우드(AWS/GCP/온프레미스) 월간 비용 데이터"
  role_arn    = aws_iam_role.bedrock_kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${data.aws_region.bedrock.name}::foundation-model/amazon.titan-embed-text-v2:0"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb.arn
      vector_index_name = "aws-cost-idx"
      field_mapping {
        vector_field   = "embedding"
        text_field     = "text"
        metadata_field = "metadata"
      }
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy.bedrock_kb,
    aws_opensearchserverless_access_policy.kb,
    null_resource.opensearch_index,
  ]
}

resource "aws_bedrockagent_data_source" "cost_chunks" {
  provider          = aws.bedrock
  knowledge_base_id = aws_bedrockagent_knowledge_base.cost.id
  name              = "aws-cost-chunks-ds"
  description       = "S3 비용 청크 데이터"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn         = data.terraform_remote_state.s3.outputs.storage_bucket_arn
      inclusion_prefixes = ["cost/chunks/"]
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = 300
        overlap_percentage = 20
      }
    }
  }
}

# ---------------------------------------------------------
# IAM — Lambda 공통 실행 역할
# ---------------------------------------------------------
resource "aws_iam_role" "lambda_exec" {
  name = "aws-cost-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "lambda_exec" {
  name = "aws-cost-lambda-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/aws-lambda-cost-*:*"
      },
      {
        Sid    = "S3ReadWrite"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [
          "${data.terraform_remote_state.s3.outputs.storage_bucket_arn}/cost/raw/*",
          "${data.terraform_remote_state.s3.outputs.storage_bucket_arn}/cost/chunks/*",
        ]
      },
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/mzclinic/cost/*"
      },
      {
        Sid    = "Bedrock"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:RetrieveAndGenerate",
          "bedrock:Retrieve",
        ]
        Resource = "*"
      },
      {
        Sid    = "BedrockKBSync"
        Effect = "Allow"
        Action = ["bedrock:StartIngestionJob", "bedrock:GetIngestionJob"]
        Resource = "*"
      },
      {
        Sid    = "SES"
        Effect = "Allow"
        Action = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
      },
    ]
  })
}

# ---------------------------------------------------------
# Lambda — GCP Billing Collector
# ---------------------------------------------------------
data "archive_file" "gcp_billing_collector" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/gcp_billing_collector"
  output_path = "${path.module}/lambda/gcp_billing_collector.zip"
}

resource "aws_cloudwatch_log_group" "gcp_billing_collector" {
  name              = "/aws/lambda/aws-lambda-cost-gcp-collector"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-gcp-collector" })
}

resource "aws_lambda_function" "gcp_billing_collector" {
  function_name    = "aws-lambda-cost-gcp-collector"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.gcp_billing_collector.output_path
  source_code_hash = data.archive_file.gcp_billing_collector.output_base64sha256

  environment {
    variables = {
      BUCKET          = data.terraform_remote_state.s3.outputs.storage_bucket_name
      RAW_PREFIX      = "cost/raw"
      SSM_GCP_KEY     = "/mzclinic/cost/gcp/service-account-key"
      SSM_GCP_PROJECT = "/mzclinic/cost/gcp/project-id"
      SSM_GCP_DATASET = "/mzclinic/cost/gcp/billing-dataset"
    }
  }

  depends_on = [aws_cloudwatch_log_group.gcp_billing_collector]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-gcp-collector" })
}

# ---------------------------------------------------------
# Lambda — OnPrem Cost Calculator
# ---------------------------------------------------------
data "archive_file" "onprem_cost_calculator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/onprem_cost_calculator"
  output_path = "${path.module}/lambda/onprem_cost_calculator.zip"
}

resource "aws_cloudwatch_log_group" "onprem_cost_calculator" {
  name              = "/aws/lambda/aws-lambda-cost-onprem-calc"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-onprem-calc" })
}

resource "aws_lambda_function" "onprem_cost_calculator" {
  function_name    = "aws-lambda-cost-onprem-calc"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 128
  filename         = data.archive_file.onprem_cost_calculator.output_path
  source_code_hash = data.archive_file.onprem_cost_calculator.output_base64sha256

  environment {
    variables = {
      BUCKET           = data.terraform_remote_state.s3.outputs.storage_bucket_name
      RAW_PREFIX       = "cost/raw"
      SSM_VCENTER_HOST = "/mzclinic/cost/vcenter/host"
      SSM_VCENTER_USER = "/mzclinic/cost/vcenter/username"
      SSM_VCENTER_PASS = "/mzclinic/cost/vcenter/password"
      SSM_COST_PARAMS  = "/mzclinic/cost/onprem/cost-params"
    }
  }

  depends_on = [aws_cloudwatch_log_group.onprem_cost_calculator]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-onprem-calc" })
}

# ---------------------------------------------------------
# Lambda — Cost to Knowledge Base
# ---------------------------------------------------------
data "archive_file" "cost_to_kb" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/cost_to_kb"
  output_path = "${path.module}/lambda/cost_to_kb.zip"
}

resource "aws_cloudwatch_log_group" "cost_to_kb" {
  name              = "/aws/lambda/aws-lambda-cost-to-kb"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-to-kb" })
}

resource "aws_lambda_function" "cost_to_kb" {
  function_name    = "aws-lambda-cost-to-kb"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.cost_to_kb.output_path
  source_code_hash = data.archive_file.cost_to_kb.output_base64sha256

  environment {
    variables = {
      BUCKET            = data.terraform_remote_state.s3.outputs.storage_bucket_name
      RAW_PREFIX        = "cost/raw"
      CHUNKS_PREFIX     = "cost/chunks"
      KB_ID             = aws_bedrockagent_knowledge_base.cost.id
      KB_DS_ID          = aws_bedrockagent_data_source.cost_chunks.data_source_id
      BEDROCK_REGION    = var.bedrock_region
      ANNUAL_BUDGET_KRW = tostring(var.annual_budget_krw)
      SSM_EXIM_API_KEY  = "/mzclinic/cost/exim/api-key"
    }
  }

  depends_on = [aws_cloudwatch_log_group.cost_to_kb]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-to-kb" })
}

# ---------------------------------------------------------
# Lambda — Monthly Report
# ---------------------------------------------------------
data "archive_file" "monthly_report" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/monthly_report"
  output_path = "${path.module}/lambda/monthly_report.zip"
}

resource "aws_cloudwatch_log_group" "monthly_report" {
  name              = "/aws/lambda/aws-lambda-cost-monthly-report"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-monthly-report" })
}

resource "aws_lambda_function" "monthly_report" {
  function_name    = "aws-lambda-cost-monthly-report"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 600
  memory_size      = 512
  filename         = data.archive_file.monthly_report.output_path
  source_code_hash = data.archive_file.monthly_report.output_base64sha256

  environment {
    variables = {
      KB_ID          = aws_bedrockagent_knowledge_base.cost.id
      BEDROCK_REGION = var.bedrock_region
      ADMIN_EMAIL    = var.admin_email
      SES_REGION     = var.aws_region
    }
  }

  depends_on = [aws_cloudwatch_log_group.monthly_report]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-monthly-report" })
}

# ---------------------------------------------------------
# Lambda — Cost Chat (RAG)
# ---------------------------------------------------------
data "archive_file" "cost_chat" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/cost_chat"
  output_path = "${path.module}/lambda/cost_chat.zip"
}

resource "aws_cloudwatch_log_group" "cost_chat" {
  name              = "/aws/lambda/aws-lambda-cost-chat"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-chat" })
}

resource "aws_lambda_function" "cost_chat" {
  function_name    = "aws-lambda-cost-chat"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.cost_chat.output_path
  source_code_hash = data.archive_file.cost_chat.output_base64sha256

  environment {
    variables = {
      KB_ID          = aws_bedrockagent_knowledge_base.cost.id
      BEDROCK_REGION = var.bedrock_region
    }
  }

  depends_on = [aws_cloudwatch_log_group.cost_chat]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-chat" })
}

# ---------------------------------------------------------
# Lambda — Anomaly Detector
# ---------------------------------------------------------
data "archive_file" "anomaly_detector" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/anomaly_detector"
  output_path = "${path.module}/lambda/anomaly_detector.zip"
}

resource "aws_cloudwatch_log_group" "anomaly_detector" {
  name              = "/aws/lambda/aws-lambda-cost-anomaly"
  retention_in_days = 30
  tags              = merge(local.common_tags, { Name = "aws-cwl-cost-anomaly" })
}

resource "aws_lambda_function" "anomaly_detector" {
  function_name    = "aws-lambda-cost-anomaly"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 128
  filename         = data.archive_file.anomaly_detector.output_path
  source_code_hash = data.archive_file.anomaly_detector.output_base64sha256

  environment {
    variables = {
      BUCKET      = data.terraform_remote_state.s3.outputs.storage_bucket_name
      RAW_PREFIX  = "cost/raw"
      ALERT_EMAIL = var.alert_email
      SES_REGION  = var.aws_region
    }
  }

  depends_on = [aws_cloudwatch_log_group.anomaly_detector]
  tags       = merge(local.common_tags, { Name = "aws-lambda-cost-anomaly" })
}

# ---------------------------------------------------------
# API Gateway — RAG 챗봇 엔드포인트
# ---------------------------------------------------------
resource "aws_api_gateway_rest_api" "cost_chat" {
  name        = "aws-apigw-cost-chat"
  description = "멀티클라우드 비용 RAG 챗봇 API"
  tags        = local.common_tags
}

resource "aws_api_gateway_resource" "chat" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  parent_id   = aws_api_gateway_rest_api.cost_chat.root_resource_id
  path_part   = "chat"
}

resource "aws_api_gateway_method" "chat_post" {
  rest_api_id      = aws_api_gateway_rest_api.cost_chat.id
  resource_id      = aws_api_gateway_resource.chat.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_method" "chat_options" {
  rest_api_id   = aws_api_gateway_rest_api.cost_chat.id
  resource_id   = aws_api_gateway_resource.chat.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "chat_post" {
  rest_api_id             = aws_api_gateway_rest_api.cost_chat.id
  resource_id             = aws_api_gateway_resource.chat.id
  http_method             = aws_api_gateway_method.chat_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.cost_chat.invoke_arn
}

resource "aws_api_gateway_integration" "chat_options" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.chat.id
  http_method = aws_api_gateway_method.chat_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "chat_options_200" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.chat.id
  http_method = aws_api_gateway_method.chat_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "chat_options" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id
  resource_id = aws_api_gateway_resource.chat.id
  http_method = aws_api_gateway_method.chat_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_lambda_permission" "apigw_cost_chat" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_chat.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.cost_chat.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "cost_chat" {
  rest_api_id = aws_api_gateway_rest_api.cost_chat.id

  depends_on = [
    aws_api_gateway_integration.chat_post,
    aws_api_gateway_integration.chat_options,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.cost_chat.id
  deployment_id = aws_api_gateway_deployment.cost_chat.id
  stage_name    = "prod"
  tags          = local.common_tags
}

resource "aws_api_gateway_api_key" "cost_chat" {
  name = "aws-cost-chat-key"
  tags = local.common_tags
}

resource "aws_api_gateway_usage_plan" "cost_chat" {
  name = "aws-cost-chat-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.cost_chat.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  tags = local.common_tags
}

resource "aws_api_gateway_usage_plan_key" "cost_chat" {
  key_id        = aws_api_gateway_api_key.cost_chat.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.cost_chat.id
}

# ---------------------------------------------------------
# EventBridge Scheduler — 공통 실행 역할
# ---------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name = "aws-cost-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "scheduler" {
  name = "aws-cost-scheduler-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "lambda:InvokeFunction"
      Resource = [
        aws_lambda_function.gcp_billing_collector.arn,
        aws_lambda_function.onprem_cost_calculator.arn,
        aws_lambda_function.cost_to_kb.arn,
        aws_lambda_function.anomaly_detector.arn,
        aws_lambda_function.monthly_report.arn,
      ]
    }]
  })
}

# ---------------------------------------------------------
# EventBridge Schedules
# ---------------------------------------------------------
resource "aws_scheduler_schedule" "gcp_billing_collector" {
  name        = "aws-sch-cost-gcp-collector"
  description = "GCP 빌링 데이터 수집 — 매일 01:00 KST"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 16 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.gcp_billing_collector.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_scheduler_schedule" "onprem_cost_calculator" {
  name        = "aws-sch-cost-onprem-calc"
  description = "온프레미스 비용 계산 — 매일 01:00 KST"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 16 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.onprem_cost_calculator.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_scheduler_schedule" "cost_to_kb" {
  name        = "aws-sch-cost-to-kb"
  description = "Knowledge Base 업데이트 — 매일 02:00 KST"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 17 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.cost_to_kb.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_scheduler_schedule" "anomaly_detector" {
  name        = "aws-sch-cost-anomaly"
  description = "이상 지표 감지 — 매일 03:00 KST"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 18 * * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.anomaly_detector.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

resource "aws_scheduler_schedule" "monthly_report" {
  name        = "aws-sch-cost-monthly-report"
  description = "월간 리포트 발송 — 매월 1일 09:00 KST"
  group_name  = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 0 1 * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.monthly_report.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}
