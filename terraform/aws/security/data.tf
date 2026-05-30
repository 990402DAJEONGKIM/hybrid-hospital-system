# data.tf
data "aws_vpc" "aws-vpc-01" {
  tags = { Name = "aws-vpc-01" }
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "kms" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = {
      name = "TC-aws-KMS"
    }
  }
}


data "aws_region" "current" {}