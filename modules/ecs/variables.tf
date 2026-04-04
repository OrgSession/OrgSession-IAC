variable "env" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where ECS tasks will run"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS tasks"
  type        = list(string)
}

variable "alb_target_group_arn" {
  description = "ARN of the ALB target group"
  type        = string
}

variable "alb_security_group_id" {
  description = "Security group ID of the ALB (for ingress rules)"
  type        = string
}

variable "ecr_repository_url" {
  description = "ECR repository URL for the backend image"
  type        = string
}

variable "container_image" {
  description = "Full container image URI to deploy. Defaults to a placeholder on initial provision."
  type        = string
  default     = "public.ecr.aws/docker/library/httpd:latest"
}

variable "cors_origins" {
  description = "Comma-separated list of allowed CORS origins"
  type        = string
  default     = "*"
}

variable "task_cpu" {
  description = "Fargate task CPU units"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Desired number of ECS tasks"
  type        = number
  default     = 1
}

variable "backend_port" {
  description = "Port the backend container listens on"
  type        = number
  default     = 8000
}
