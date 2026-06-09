output "storage_bucket_name" {
  value = aws_s3_bucket.storage.bucket
}

output "storage_bucket_arn" {
  value = aws_s3_bucket.storage.arn
}