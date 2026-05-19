  #securtiygroup.tf
  resource "aws_security_group" "aws-wazuh-sg" {
    name        = "aws-wazuh-sg"
    vpc_id      = data.aws_vpc.aws-vpc-01.id
    description = "Wazuh server"

    ingress {
      from_port   = 1514
      to_port     = 1514
      protocol    = "tcp"
      cidr_blocks = ["10.0.0.0/16", "172.30.1.0/24"]
    }

    ingress {

      from_port   = 1515
      to_port     = 1515
      protocol    = "tcp"
      cidr_blocks = ["10.0.0.0/16", "172.30.1.0/24"]
    }

    ingress {
      from_port   = 1516
      to_port     = 1516
      protocol    = "tcp"
      cidr_blocks = ["10.0.0.0/16"]
    }

    ingress {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }

    ingress {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
      Name  = "aws-wazuh-sg"
      Owner = "st2"
    }
  }