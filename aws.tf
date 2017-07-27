variable "access_key" {}
variable "secret_key" {}

variable "regions" {
  type = "map"

  default = {
    "dev-mpalmer" = "ap-southeast-2"
    "dev-aj"      = "eu-central-1"
  }
}

provider "aws" {
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  region     = "${lookup(var.regions, terraform.env)}"
}
