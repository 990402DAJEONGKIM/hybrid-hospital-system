# data.tf
data "aws_vpc" "aws-vpc-01" {
  tags = { Name = "aws-vpc-01" }
}

data "aws_caller_identity" "aws-caller-current-01" {}