# Public Routing Table
resource "aws_route_table" "aws-rt-pub-01" {
  vpc_id = aws_vpc.aws-vpc-01.id

  tags = {
    Name  = "aws-rt-pub-01"
    Owner = "st2"
  }
}

resource "aws_route" "aws-rt-pub-01-route" {
  route_table_id         = aws_route_table.aws-rt-pub-01.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.aws-igw-01.id
}

resource "aws_route_table_association" "aws-rt-pub-01-assoc" {
  for_each       = aws_subnet.aws-pub-sub
  route_table_id = aws_route_table.aws-rt-pub-01.id
  subnet_id      = each.value.id
}

# App Routing Table
resource "aws_route_table" "aws-rt-app-01" {
  vpc_id = aws_vpc.aws-vpc-01.id

  tags = {
    Name  = "aws-rt-app-01"
    Owner = "st2"
  }
}

resource "aws_route" "aws-rt-app-01-route" {
  route_table_id         = aws_route_table.aws-rt-app-01.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.aws-nat-01.id
}

resource "aws_route_table_association" "aws-rt-app-01-assoc" {
  for_each       = aws_subnet.aws-app-sub
  route_table_id = aws_route_table.aws-rt-app-01.id
  subnet_id      = each.value.id
}

# DB Routing Table
resource "aws_route_table" "aws-rt-db-01" {
  vpc_id = aws_vpc.aws-vpc-01.id

  tags = {
    Name  = "aws-rt-db-01"
    Owner = "st2"
  }
}



resource "aws_route_table_association" "aws-rt-db-01-assoc" {
  for_each       = aws_subnet.aws-db-sub
  route_table_id = aws_route_table.aws-rt-db-01.id
  subnet_id      = each.value.id
}


