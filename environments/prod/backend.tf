terraform {
  backend "s3" {
    bucket         = "github-session-my-org-terraform-state"
    key            = "orgsession/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "github-session-my-org-terraform-locks"
    encrypt        = true
  }
}
