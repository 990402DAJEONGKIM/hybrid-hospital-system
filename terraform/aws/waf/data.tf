data "aws_lb" "patient" {
  name = var.patient_alb_name
}

data "aws_lb" "staff" {
  name = var.staff_alb_name
}


data "terraform_remote_state" "aws-kms" {
  backend = "remote"
  config = {
    organization = "k2p"
    workspaces = { name = "TC-aws-KMS" }
  }
}