resource "aws_flow_log" "aws-vpc-flowlog" {
  vpc_id          = data.aws_vpc.aws-vpc-01.id
  traffic_type    = "ALL"
  log_destination_type     = "s3"
  log_destination = "arn:aws:s3:::aws-k2p-storage-01/flowlogs/"
}
