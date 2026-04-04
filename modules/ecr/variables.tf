variable "env" {
  description = "Deployment environment (dev or prod)"
  type        = string
}

variable "image_tag_mutability" {
  description = "Mutability setting for image tags"
  type        = string
  default     = "MUTABLE"
}

variable "max_image_count" {
  description = "Maximum number of images to retain in ECR"
  type        = number
  default     = 5
}
