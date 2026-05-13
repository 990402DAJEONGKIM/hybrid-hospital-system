# ssm 연결을 위한 IAM Role (EC2가 SSM 서비스를 쓸 수 있게 허용)
resource "aws_iam_role" "aws_bastion_role" {
  name = "aws-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# SSM 관리형 정책 연결
resource "aws_iam_role_policy_attachment" "aws_ssm_attachment" {
  role       = aws_iam_role.aws_bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 3. EC2 인스턴스 프로파일
resource "aws_iam_instance_profile" "aws_bastion_profile" {
  name = "aws-bastion-profile"
  role = aws_iam_role.aws_bastion_role.name
}

# 베스천 전용 보안 그룹
resource "aws_security_group" "aws_bastion_sg" {
  name   = "aws-bastion-sg"
  vpc_id = data.aws_vpc.aws_vpc-01.id

  # 아웃바운드는 RDS(5432) 접근을 위해 전체 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 5. 베스천 EC2 인스턴스 생성
resource "aws_instance" "aws_bastion_01" {
  ami                  = "ami-040c33c6a51fd5d96" # ap-south-2 리전 Amazon Linux 2023
  instance_type        = "t3.micro"
  iam_instance_profile = aws_iam_instance_profile.aws_bastion_profile.name
  
  subnet_id              = data.aws_subnet.aws-pub-sub-2a.id
  vpc_security_group_ids = [aws_security_group.aws_bastion_sg.id]

  tags = {
    Name = "aws-bastion-01"
  }
}