resource "aws_s3_bucket" "demo_bucket" {
  bucket = "orgsession-demo-bucket-${var.env}"

  tags = {
    Name        = "orgsession-demo-bucket-${var.env}"
    Environment = var.env
  }
}

resource "aws_s3_bucket" "demo_bucket_v2" {
  bucket = "orgsession-demo-bucket-${var.env}-v2"

  tags = {
    Name        = "orgsession-demo-bucket-${var.env}-v2"
    Environment = var.env
  }
}
resource "aws_s3_bucket" "demo_bucket_v3" {
  bucket = "orgsession-demo-bucket-${var.env}-v3"

  tags = {
    Name        = "orgsession-demo-bucket-${var.env}-v3"
    Environment = var.env
  }
}