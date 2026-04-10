# Staging uses LocalStack — a local Docker container that emulates AWS services
# at localhost:4566. No real AWS credentials are needed.
#
# Start LocalStack before running terraform apply:
#   docker run -d -p 4566:4566 localstack/localstack
provider "aws" {
  region                      = var.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  endpoints {
    s3             = "http://localhost:4566"
    iam            = "http://localhost:4566"
    secretsmanager = "http://localhost:4566"
  }
}