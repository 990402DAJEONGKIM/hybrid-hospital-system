data "terraform_remote_state" "s3" {
  backend = "remote"

  config = {
    organization = "k2p"
    workspaces = {
      name = "TC-aws-S3"
    }
  }
}

data "aws_kms_key" "s3" {
  key_id = "alias/aws-kms-s3-01"
}

