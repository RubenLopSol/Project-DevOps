terraform {
  backend "s3" {
    bucket         = "openpanel-terraform-state"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "openpanel-terraform-locks"
  }
}
