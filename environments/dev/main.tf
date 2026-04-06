locals {
  env = "dev"
}

module "vpc" {
  source = "../../modules/vpc"

  env                  = local.env
  availability_zones   = var.availability_zones
  vpc_cidr             = "10.0.0.0/16"
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
}

module "ecr" {
  source = "../../modules/ecr"

  env             = local.env
  max_image_count = 5
}

module "alb" {
  source = "../../modules/alb"

  env               = local.env
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  backend_port      = 8000
  health_check_path = "/status"
}

module "s3_cloudfront" {
  source = "../../modules/s3_cloudfront"

  env            = local.env
  aws_account_id = var.aws_account_id
  alb_dns_name   = module.alb.alb_dns_name
}

module "ecs" {
  source = "../../modules/ecs"

  env                   = local.env
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  alb_target_group_arn  = module.alb.target_group_arn
  alb_security_group_id = module.alb.alb_security_group_id
  ecr_repository_url    = module.ecr.repository_url
  cors_origins          = "https://${module.s3_cloudfront.cloudfront_domain_name}"
  task_cpu              = 256
  task_memory           = 512
  desired_count         = 1
}

module "secrets" {
  source = "../../modules/secrets"

  env                        = local.env
  api_url                    = "https://${module.s3_cloudfront.cloudfront_domain_name}"
  s3_bucket                  = module.s3_cloudfront.bucket_name
  cloudfront_distribution_id = module.s3_cloudfront.cloudfront_distribution_id
  cloudfront_domain_name     = module.s3_cloudfront.cloudfront_domain_name
  ecr_repository_url         = module.ecr.repository_url
  ecr_repository_name        = module.ecr.repository_name
  ecs_cluster_name           = module.ecs.cluster_name
  ecs_service_name           = module.ecs.service_name
}

module "s3"{
  source = "../../modules/s3"

  env = local.env
}