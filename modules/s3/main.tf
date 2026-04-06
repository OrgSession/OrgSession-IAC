resource "aws_s3_bucket" "demo_bucket" {
  bucket = "orgsession-demo-bucket-${var.env}"

  tags = {
    Name        = "orgsession-demo-bucket-${var.env}"
    Environment = var.env
  }
}