variable "env" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "api_url" {
  description = "Backend ALB URL to store in Secrets Manager"
  type        = string
}

variable "s3_bucket" {
  description = "S3 bucket name for the frontend"
  type        = string
}

variable "cloudfront_distribution_id" {
  description = "CloudFront distribution ID for the frontend"
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL for the backend"
  type        = string
}

variable "ecr_repository_name" {
  description = "ECR repository name for the backend"
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name"
  type        = string
}

variable "ecs_service_name" {
  description = "ECS service name"
  type        = string
}

variable "cloudfront_domain_name" {
  description = "CloudFront distribution domain name"
  type        = string
}
