terraform {
  backend "s3" {
    bucket         = "discourse-tfstate"
    key            = "tfstate"
    region         = "eu-central-1"
    dynamodb_table = "discourse-tfstate"
  }
}
