resource "aws_vpc" "aws-vpc-01" {
  cidr_block           = local.vpc_cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name  = "aws-vpc-01"
    Owner = "st2"
  }
}
