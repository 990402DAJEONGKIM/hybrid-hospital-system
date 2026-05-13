# =============================================================================
# imports.tf — VPC 모듈 기존 리소스 Import
# =============================================================================

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
import {
  to = aws_vpc.aws-vpc-01
  id = "vpc-032134a80cdaa051e"
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------
import {
  to = aws_internet_gateway.aws-igw-01
  id = "igw-0dd9a05950462e0a2"
}

# -----------------------------------------------------------------------------
# Elastic IP (NAT용)
# -----------------------------------------------------------------------------
import {
  to = aws_eip.aws-eip-nat-01
  id = "eipalloc-0aa06bf870ae829cc"
}

# -----------------------------------------------------------------------------
# NAT Gateway
# -----------------------------------------------------------------------------
import {
  to = aws_nat_gateway.aws-nat-01
  id = "nat-090df3f4cf50ed202"
}

# -----------------------------------------------------------------------------
# Public Subnets
# -----------------------------------------------------------------------------
import {
  to = aws_subnet.aws-pub-sub["ap-south-2a"]
  id = "subnet-09b14e368033fc204"
}

import {
  to = aws_subnet.aws-pub-sub["ap-south-2b"]
  id = "subnet-0bc44b7e0ab188359"
}

import {
  to = aws_subnet.aws-pub-sub["ap-south-2c"]
  id = "subnet-0281e23f563f35429"
}

# -----------------------------------------------------------------------------
# App Subnets
# -----------------------------------------------------------------------------
import {
  to = aws_subnet.aws-app-sub["ap-south-2a"]
  id = "subnet-03a995e88f620566e"
}

import {
  to = aws_subnet.aws-app-sub["ap-south-2b"]
  id = "subnet-043fe497537a7b41b"
}

import {
  to = aws_subnet.aws-app-sub["ap-south-2c"]
  id = "subnet-0853e4e9ac72559c1"
}

# -----------------------------------------------------------------------------
# DB Subnets
# -----------------------------------------------------------------------------
import {
  to = aws_subnet.aws-db-sub["ap-south-2a"]
  id = "subnet-0b8832d70402ea32f"
}

import {
  to = aws_subnet.aws-db-sub["ap-south-2b"]
  id = "subnet-0379adc4328e2ed4e"
}

import {
  to = aws_subnet.aws-db-sub["ap-south-2c"]
  id = "subnet-09776b3770fe639ee"
}

# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------
import {
  to = aws_route_table.aws-rt-pub-01
  id = "rtb-05f4ab01affbf8b28"
}

import {
  to = aws_route_table.aws-rt-app-01
  id = "rtb-0026d25c4d45ad41a"
}

import {
  to = aws_route_table.aws-rt-db-01
  id = "rtb-08dec2fa3df43ed85"
}

# -----------------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------------
import {
  to = aws_route.aws-rt-pub-01-route
  id = "rtb-05f4ab01affbf8b28_0.0.0.0/0"
}

import {
  to = aws_route.aws-rt-app-01-route
  id = "rtb-0026d25c4d45ad41a_0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# Route Table Associations — Public (형식: subnet-id/rtb-id)
# -----------------------------------------------------------------------------
import {
  to = aws_route_table_association.aws-rt-pub-01-assoc["ap-south-2a"]
  id = "subnet-09b14e368033fc204/rtb-05f4ab01affbf8b28"
}

import {
  to = aws_route_table_association.aws-rt-pub-01-assoc["ap-south-2b"]
  id = "subnet-0bc44b7e0ab188359/rtb-05f4ab01affbf8b28"
}

import {
  to = aws_route_table_association.aws-rt-pub-01-assoc["ap-south-2c"]
  id = "subnet-0281e23f563f35429/rtb-05f4ab01affbf8b28"
}

# -----------------------------------------------------------------------------
# Route Table Associations — App (형식: subnet-id/rtb-id)
# -----------------------------------------------------------------------------
import {
  to = aws_route_table_association.aws-rt-app-01-assoc["ap-south-2a"]
  id = "subnet-03a995e88f620566e/rtb-0026d25c4d45ad41a"
}

import {
  to = aws_route_table_association.aws-rt-app-01-assoc["ap-south-2b"]
  id = "subnet-043fe497537a7b41b/rtb-0026d25c4d45ad41a"
}

import {
  to = aws_route_table_association.aws-rt-app-01-assoc["ap-south-2c"]
  id = "subnet-0853e4e9ac72559c1/rtb-0026d25c4d45ad41a"
}

# -----------------------------------------------------------------------------
# Route Table Associations — DB (형식: subnet-id/rtb-id)
# -----------------------------------------------------------------------------
import {
  to = aws_route_table_association.aws-rt-db-01-assoc["ap-south-2a"]
  id = "subnet-0b8832d70402ea32f/rtb-08dec2fa3df43ed85"
}

import {
  to = aws_route_table_association.aws-rt-db-01-assoc["ap-south-2b"]
  id = "subnet-0379adc4328e2ed4e/rtb-08dec2fa3df43ed85"
}

import {
  to = aws_route_table_association.aws-rt-db-01-assoc["ap-south-2c"]
  id = "subnet-09776b3770fe639ee/rtb-08dec2fa3df43ed85"
}

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------
import {
  to = aws_security_group.aws-alb-sg
  id = "sg-0033dc56b64ef6c4b"
}

import {
  to = aws_security_group.aws-app-sg
  id = "sg-0169b1764a2fb7aee"
}

import {
  to = aws_security_group.aws-ssh-sg
  id = "sg-0f8163f833b2eeaff"
}
