# Configure the Cloudflare provider
provider "cloudflare" {
  email = "${var.cloudflare_email}"
  token = "${var.cloudflare_token}"
}

variable "cloudflare_domain" {
  default = "discourse.cloud"
}

variable "cloudflare_email" {}
variable "cloudflare_token" {}
