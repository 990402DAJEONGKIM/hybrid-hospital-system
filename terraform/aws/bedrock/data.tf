data "terraform_remote_state" "s3" {
  backend = "remote"

  config = {
    organization = "k2p"
    workspaces = {
      name = "TC-aws-S3"
    }
  }
}
