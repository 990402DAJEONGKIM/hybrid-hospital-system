locals {
  az_names = data.aws_availability_zones.available_az.names

  vpc_cidr_block = "10.0.0.0/16"

  public_cidr_blocks = [
    for i in range(length(local.az_names)) : "10.0.${i + 1}.0/24"
  ]
  app_cidr_blocks = [
    for i in range(length(local.az_names)) : "10.0.${i + 11}.0/24"
  ]
  db_cidr_blocks = [
    for i in range(length(local.az_names)) : "10.0.${i + 21}.0/24"
  ]

  az_suffix = {
    for az in local.az_names : az => replace(az, "ap-south-", "")
  }
}
