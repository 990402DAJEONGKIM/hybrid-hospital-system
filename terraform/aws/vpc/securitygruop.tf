# ALB 보안그룹
resource "aws_security_group" "aws-alb-sg" {
  name        = "aws-alb-sg"
  vpc_id      = aws_vpc.aws-vpc-01.id
  description = "Allow HTTP and HTTPS Traffic"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
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
    Name  = "aws-alb-sg"
    Owner = "st2"
  }
}

# EC2 보안그룹
resource "aws_security_group" "aws-app-sg" {
  name        = "aws-app-sg"
  vpc_id      = aws_vpc.aws-vpc-01.id
  description = "Allow traffic from ALB only"

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.aws-alb-sg.id]
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
    Name  = "aws-app-sg"
    Owner = "st2"
  }
}



# SSH 보안그룹
resource "aws_security_group" "aws-ssh-sg" {
  name        = "aws-ssh-sg"
  vpc_id      = aws_vpc.aws-vpc-01.id
  description = "Allow SSH Traffic"

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
    Name  = "aws-ssh-sg"
    Owner = "st2"
  }
}


