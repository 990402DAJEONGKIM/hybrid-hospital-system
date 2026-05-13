# Public Subnet
resource "aws_subnet" "aws-pub-sub" {
  for_each = toset(local.az_names)

  vpc_id                                      = aws_vpc.aws-vpc-01.id
  cidr_block                                  = local.public_cidr_blocks[index(local.az_names, each.value)]
  map_public_ip_on_launch                     = true
  enable_resource_name_dns_a_record_on_launch = true
  availability_zone                           = each.value

  tags = {
    Name  = "aws-pub-sub-${local.az_suffix[each.value]}"
    Owner = "st2"
  }
}

# App Subnet (Private)
resource "aws_subnet" "aws-app-sub" {
  for_each = toset(local.az_names)

  vpc_id            = aws_vpc.aws-vpc-01.id
  cidr_block        = local.app_cidr_blocks[index(local.az_names, each.value)]
  availability_zone = each.value

  tags = {
    Name  = "aws-app-sub-${local.az_suffix[each.value]}"
    Owner = "st2"
  }
}

# DB Subnet (Private)
resource "aws_subnet" "aws-db-sub" {
  for_each = toset(local.az_names)

  vpc_id            = aws_vpc.aws-vpc-01.id
  cidr_block        = local.db_cidr_blocks[index(local.az_names, each.value)]
  availability_zone = each.value

  tags = {
    Name  = "aws-db-sub-${local.az_suffix[each.value]}"
    Owner = "st2"
  }
}
