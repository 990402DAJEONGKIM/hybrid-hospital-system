#data.tf
data "aws_vpc" "aws-vpc-01" {
  tags = { Name = "aws-vpc-01" }
}

data "aws_subnet" "aws-app-sub-2c" {
  tags = { Name = "aws-app-sub-2c" }
}



data "terraform_remote_state" "wazuh" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = {
      name = "TC-aws-wazuh"
    }
  }
}


data "terraform_remote_state" "kms" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = {
      name = "TC-aws-KMS"
    }
  }
}

output "indexer_instance_id" {
  value = aws_instance.aws-wazuh-indexer.id
}