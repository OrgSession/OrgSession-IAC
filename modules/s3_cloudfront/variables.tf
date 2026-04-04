variable "env" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID for unique S3 bucket naming"
  type        = string
}

variable "default_root_object" {
  description = "Default root object for CloudFront"
  type        = string
  default     = "index.html"
}
