terraform {
  backend "s3" {
    bucket         = "wombles-whacky-whatsit"
    key            = "tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "wombles-whacky-whatsit"
  }
}
