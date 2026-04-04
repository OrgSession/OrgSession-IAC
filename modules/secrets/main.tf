resource "aws_secretsmanager_secret" "config" {
  name                    = "orgsession/${var.env}/config"
  description             = "Configuration for OrgSession ${var.env} environment"
  recovery_window_in_days = 0

  tags = {
    Environment = var.env
  }
}

resource "aws_secretsmanager_secret_version" "config" {
  secret_id = aws_secretsmanager_secret.config.id
  secret_string = jsonencode({
    api_url                    = var.api_url
    s3_bucket                  = var.s3_bucket
    cloudfront_distribution_id = var.cloudfront_distribution_id
    cloudfront_domain_name     = var.cloudfront_domain_name
    ecr_repository_url         = var.ecr_repository_url
    ecr_repository_name        = var.ecr_repository_name
    ecs_cluster_name           = var.ecs_cluster_name
    ecs_service_name           = var.ecs_service_name
  })
}
