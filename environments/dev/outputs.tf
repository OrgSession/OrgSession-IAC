output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = module.alb.alb_dns_name
}

output "cloudfront_domain_name" {
  description = "Domain name of the CloudFront distribution"
  value       = module.s3_cloudfront.cloudfront_domain_name
}

output "cloudfront_distribution_id" {
  description = "ID of the CloudFront distribution"
  value       = module.s3_cloudfront.cloudfront_distribution_id
}

output "ecr_repository_url" {
  description = "ECR repository URL for the backend"
  value       = module.ecr.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = module.ecs.service_name
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for the frontend"
  value       = module.s3_cloudfront.bucket_name
}

output "secrets_manager_secret_name" {
  description = "Name of the Secrets Manager secret"
  value       = module.secrets.secret_name
}
