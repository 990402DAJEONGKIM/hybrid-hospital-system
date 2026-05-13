resource "aws_eip" "aws-eip-nat-01" {
  domain = "vpc"

  tags = {
    Name  = "aws-eip-nat-01"
    Owner = "st2"
  }
}

resource "aws_nat_gateway" "aws-nat-01" {
  allocation_id = aws_eip.aws-eip-nat-01.id
  subnet_id     = aws_subnet.aws-pub-sub[keys(aws_subnet.aws-pub-sub)[0]].id

  depends_on = [aws_internet_gateway.aws-igw-01]

  tags = {
    Name  = "aws-nat-01"
    Owner = "st2"
  }
}
