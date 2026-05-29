resource "aws_flow_log" "aws-vpc-flowlog" {
  vpc_id          = data.aws_vpc.aws-vpc-01.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.aws-iam-role-flowlog.arn
  log_destination = aws_cloudwatch_log_group.aws-cloudwatch-vpcflow.arn
}

resource "aws_cloudwatch_log_group" "aws-cloudwatch-vpcflow" {
  name              = "/aws/vpc/flowlogs"
  retention_in_days = 90
}

resource "aws_iam_role" "aws-iam-role-flowlog" {
  name = "aws-iam-role-flowlog"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "aws-iam-policy-flowlog" {
  name = "aws-iam-policy-flowlog"
  role = aws_iam_role.aws-iam-role-flowlog.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup", "logs:CreateLogStream",
        "logs:PutLogEvents", "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}