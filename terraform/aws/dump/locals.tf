locals {
  # dump Lambda
  dump_name        = "aws-lambda-dump"
  dump_role_name   = "aws-role-dump"
  dump_sg_name     = "aws-sg-dump"
  dump_ecr_name    = "aws-ecr-dump"
  dump_sch_name    = "aws-sch-dump"
  dump_cwl_name    = "/aws/lambda/aws-lambda-dump"
  dump_s3_prefix   = "db-dumps/rds"
  dump_schedule    = var.db_dump_schedule_cron

  # rotation Lambda
  rotation_name      = "aws-lambda-rotation"
  rotation_role_name = "aws-role-rotation"
  rotation_ecr_name  = "aws-ecr-rotation"
  rotation_cwl_name  = "/aws/lambda/aws-lambda-rotation"

}
