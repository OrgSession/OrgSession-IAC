variable "env" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the ALB will be deployed"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the ALB"
  type        = list(string)
}

variable "backend_port" {
  description = "Port the backend container listens on"
  type        = number
  default     = 8000
}

variable "health_check_path" {
  description = "Path for ALB health checks"
  type        = string
  default     = "/status"
}
