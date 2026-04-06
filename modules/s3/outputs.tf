output "demo_bucket_arn" {
  value = aws_s3_bucket.demo_bucket.arn
  description = "Organization Session Demo Bucket Amazon Resource Number"
}