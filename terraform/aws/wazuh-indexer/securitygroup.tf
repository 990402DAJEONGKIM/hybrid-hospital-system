#securitygroup.tf
resource "aws_security_group" "aws-wazuh-indexer-sg" {
  name        = "aws-wazuh-indexer-sg"
  vpc_id      = data.aws_vpc.aws-vpc-01.id
  description = "Wazuh Indexer"

  # Manager(Filebeat) + Dashboard → Indexer
  ingress {
    from_port   = 9200
    to_port     = 9200
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name  = "aws-wazuh-indexer-sg"
    Owner = "st2"
  }
}
