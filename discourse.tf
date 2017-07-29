#################
### VARIABLES ###
#################

# IMPORTANT: The variables defined below are defaults only. You should not need to edit this file directly.
# Any variable specified below can be overridden in terraform.tfvars; all credentials and other configuration should be entered there.
# If you need to change a hardcoded value in this file, consider replacing it with a variable.
# For more information, see README.md.

variable "app_instance_type" {}
variable "domain" {}
variable "public_key_name" {}
variable "DISCOURSE_DB_USERNAME" {}
variable "DISCOURSE_DB_PASSWORD" {}
variable "DISCOURSE_DEVELOPER_EMAILS" {}
variable "DISCOURSE_SMTP_ADDRESS" {}
variable "DISCOURSE_SMTP_USER_NAME" {}
variable "DISCOURSE_SMTP_PASSWORD" {}
variable "DISCOURSE_SMTP_PORT" {}
variable "LANG" {}
variable "LETSENCRYPT_ACCOUNT_EMAIL" {}

############
### DATA ###
############

# Dynamically find the most recent AMI matching the criteria defined below
data "aws_ami" "discourse_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["*ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }

  filter {
    name   = "description"
    values = ["*16.04 LTS*"]
  }

  filter {
    name   = "is-public"
    values = ["true"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "hypervisor"
    values = ["xen"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "block-device-mapping.delete-on-termination"
    values = ["true"]
  }

  filter {
    name   = "block-device-mapping.volume-type"
    values = ["gp2"]
  }

  filter {
    name   = "block-device-mapping.volume-size"
    values = ["8"]
  }
}

# Associate an identifier with the Postgres database so that we can add the app instance to its security group
data "aws_db_instance" "database" {
  db_instance_identifier = "${aws_db_instance.discourse_postgres.identifier}"
}

data "aws_availability_zones" "available" {}

data "aws_elb_service_account" "main" {}

#################
### RESOURCES ###
#################

resource "aws_alb" "discourse_alb" {
  name            = "discourse-alb-${terraform.env}"
  internal        = false
  security_groups = ["${aws_vpc.discourse_vpc.default_security_group_id}", "${aws_security_group.allow_all.id}"]
  subnets         = ["${aws_subnet.a.id}", "${aws_subnet.b.id}"]

  access_logs {
    bucket = "${aws_s3_bucket.discourse_log_bucket.bucket}"
    prefix = "log/alb"
  }

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_alb_listener" "frontend" {
  load_balancer_arn = "${aws_alb.discourse_alb.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.frontend.arn}"
    type             = "forward"
  }
}

resource "aws_alb_target_group" "frontend" {
  name     = "tf-discourse-alb-tg-${terraform.env}"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "${aws_vpc.discourse_vpc.id}"

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_alb_target_group_attachment" "frontend" {
  target_group_arn = "${aws_alb_target_group.frontend.arn}"
  target_id        = "${aws_instance.discourse_app.id}"
  port             = 80
}

resource "aws_instance" "discourse_app" {
  ami = "${data.aws_ami.discourse_ami.id}"

  instance_type = "${var.app_instance_type}"
  key_name      = "${var.public_key_name}"
  user_data     = "${file("userdata.sh")}"
  subnet_id     = "${aws_subnet.a.id}"
  depends_on    = ["aws_internet_gateway.discourse_gw"]

  vpc_security_group_ids = [
    "${aws_vpc.discourse_vpc.default_security_group_id}",
    "${aws_security_group.allow_all.id}",
    "${data.aws_db_instance.database.vpc_security_groups[0]}",
  ]

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_db_instance" "discourse_postgres" {
  name                 = "discourse"
  engine               = "postgres"
  engine_version       = "9.5.6"
  instance_class       = "db.t2.micro"
  allocated_storage    = 5
  storage_type         = "gp2"
  username             = "${var.DISCOURSE_DB_USERNAME}"
  password             = "${var.DISCOURSE_DB_PASSWORD}"
  db_subnet_group_name = "${aws_db_subnet_group.discourse_db_subnet_group.name}"
  parameter_group_name = "default.postgres9.5"
  skip_final_snapshot  = true

  vpc_security_group_ids = [
    "${aws_vpc.discourse_vpc.default_security_group_id}",
    "${aws_security_group.allow_all.id}",
  ]

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_db_subnet_group" "discourse_db_subnet_group" {
  name = "discourse-${terraform.env}"

  subnet_ids = ["${aws_subnet.a.id}", "${aws_subnet.b.id}"]

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_elasticache_subnet_group" "discourse_elasticache_subnet" {
  name       = "discourse-${terraform.env}"
  subnet_ids = ["${aws_subnet.a.id}", "${aws_subnet.b.id}"]
}

resource "aws_elasticache_cluster" "discourse_redis" {
  cluster_id           = "discourse-redis"
  engine               = "redis"
  node_type            = "cache.t2.medium"
  port                 = 6379
  num_cache_nodes      = 1
  parameter_group_name = "default.redis3.2"
  subnet_group_name    = "${aws_elasticache_subnet_group.discourse_elasticache_subnet.name}"
  availability_zone    = "${data.aws_availability_zones.available.names[1]}"

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_internet_gateway" "discourse_gw" {
  vpc_id = "${aws_vpc.discourse_vpc.id}"

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_kms_key" "discourse_kms_key" {
  description             = "KMS key 1"
  deletion_window_in_days = 10
}

resource "aws_route" "route" {
  route_table_id         = "${aws_vpc.discourse_vpc.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.discourse_gw.id}"
}

resource "aws_s3_bucket" "discourse_log_bucket" {
  bucket = "discourse-log-bucket-${terraform.env}"
  acl    = "log-delivery-write"

  logging {
    target_bucket = "discourse-log-bucket-${terraform.env}"
    target_prefix = "log/self/"
  }

  policy = <<POLICY
{
  "Id": "Policy",
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:PutObject"
      ],
      "Effect": "Allow",
      "Resource": "arn:aws:s3:::discourse-log-bucket-${terraform.env}/log/*",
      "Principal": {
        "AWS": [
          "${data.aws_elb_service_account.main.arn}"
        ]
      }
    }
  ]
}
POLICY

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_security_group" "allow_all" {
  name        = "allow_all"
  description = "Allow all traffic"
  vpc_id      = "${aws_vpc.discourse_vpc.id}"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_subnet" "a" {
  vpc_id = "${aws_vpc.discourse_vpc.id}"

  availability_zone = "${data.aws_availability_zones.available.names[0]}"

  cidr_block              = "${cidrsubnet(aws_vpc.discourse_vpc.cidr_block, 8, 1)}"
  map_public_ip_on_launch = true
  depends_on              = ["aws_internet_gateway.discourse_gw"]

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_subnet" "b" {
  vpc_id            = "${aws_vpc.discourse_vpc.id}"
  availability_zone = "${data.aws_availability_zones.available.names[1]}"
  cidr_block        = "${cidrsubnet(aws_vpc.discourse_vpc.cidr_block, 8, 2)}"
}

resource "aws_vpc" "discourse_vpc" {
  cidr_block = "10.0.0.0/16"

  enable_dns_hostnames = true

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_autoscaling_group" "discourse_ag" {
  vpc_zone_identifier       = ["${aws_subnet.a.id}", "${aws_subnet.b.id}"]
  name                      = "discourse-terraform-ag"
  max_size                  = 3
  min_size                  = 1
  health_check_grace_period = 500
  health_check_type         = "ELB"
  desired_capacity          = 1
  force_delete              = false
  target_group_arns         = ["${aws_alb_target_group.frontend.arn}"]
  wait_for_capacity_timeout = 0

  launch_configuration = "${aws_launch_configuration.discourse_lc.name}"

  tag {
    key                 = "Name"
    value               = "discourse-${terraform.env}"
    propagate_at_launch = true
  }

  tag {
    key                 = "Source"
    value               = "terraform"
    propagate_at_launch = true
  }
}

resource "aws_launch_configuration" "discourse_lc" {
  name_prefix                 = "terraform-lc-"
  image_id                    = "${data.aws_ami.discourse_ami.id}"
  instance_type               = "t2.micro"
  security_groups             = ["${aws_vpc.discourse_vpc.default_security_group_id}", "${aws_security_group.allow_all.id}"]
  user_data                   = "${file("userdata.sh")}"
  key_name                    = "${var.public_key_name}"
  associate_public_ip_address = true

  lifecycle {
    create_before_destroy = true
  }
}

################################################# PROD DNS ###

# Delegate the prod subdomain from CloudFlare to AWS

resource "cloudflare_record" "prod-ns0" {
  domain = "${var.domain}"
  name   = "prod"
  type   = "NS"
  ttl    = "1"
  value  = "${aws_route53_zone.prod.name_servers[0]}"
}

resource "cloudflare_record" "prod-ns1" {
  domain = "${var.domain}"
  name   = "prod"
  type   = "NS"
  ttl    = "1"
  value  = "${aws_route53_zone.prod.name_servers[1]}"
}

resource "cloudflare_record" "prod-ns2" {
  domain = "${var.domain}"
  name   = "prod"
  type   = "NS"
  ttl    = "1"
  value  = "${aws_route53_zone.prod.name_servers[2]}"
}

resource "cloudflare_record" "prod-ns3" {
  domain = "${var.domain}"
  name   = "prod"
  type   = "NS"
  ttl    = "1"
  value  = "${aws_route53_zone.prod.name_servers[3]}"
}

# Route53 zone file for prod subdomain

resource "aws_route53_zone" "prod" {
  name = "prod.${var.domain}"

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

# prod zone resource records

resource "aws_route53_record" "www_prod" {
  zone_id = "${aws_route53_zone.prod.zone_id}"

  name       = "www"
  type       = "CNAME"
  depends_on = ["aws_route53_zone.prod", "aws_alb.discourse_alb"]
  records    = ["${aws_alb.discourse_alb.dns_name}"]
  ttl        = 60
}

################################################# DEV DNS ###

# Delegate the dev subdomain

resource "cloudflare_record" "dev_subdomain-ns0" {
  domain = "${var.domain}"
  name   = "dev"
  type   = "NS"
  ttl    = "1"
  value  = "${aws_route53_zone.dev.name_servers[0]}"
}

resource "cloudflare_record" "dev_subdomain-ns1" {
  domain = "${var.domain}"
  name   = "dev"
  type   = "NS"
  ttl    = "1"
  value  = "${aws_route53_zone.dev.name_servers[1]}"
}

resource "cloudflare_record" "dev_subdomain-ns2" {
  domain = "${var.domain}"
  name   = "dev"
  type   = "NS"
  ttl    = "1"
  value  = "${aws_route53_zone.dev.name_servers[2]}"
}

resource "cloudflare_record" "dev_subdomain-ns3" {
  domain = "${var.domain}"
  name   = "dev"
  type   = "NS"
  ttl    = "1"
  value  = "${aws_route53_zone.dev.name_servers[3]}"
}

resource "aws_route53_zone" "dev" {
  name = "dev.${var.domain}"

  tags {
    Name   = "discourse-${terraform.env}"
    Source = "terraform"
  }
}

resource "aws_route53_record" "dev_subdomain" {
  zone_id    = "${aws_route53_zone.dev.zone_id}"
  name       = "${terraform.env}"
  type       = "CNAME"
  depends_on = ["aws_route53_zone.dev", "aws_alb.discourse_alb"]
  records    = ["${aws_alb.discourse_alb.dns_name}"]
  ttl        = 60
}

###############
### OUTPUTS ###
###############

# The outputs defined below can be accessed via terraform, e.g. `terraform output DISCOURSE_DB_HOST`.
# These are used to generate the .env that is copied to the Discourse host for easier setup.

output "DISCOURSE_APP_PUBLIC_IP" {
  value = "${aws_instance.discourse_app.public_ip}"
}

output "DISCOURSE_DB_HOST" {
  value = "${aws_db_instance.discourse_postgres.address}"
}

output "DISCOURSE_DB_NAME" {
  value = "${aws_db_instance.discourse_postgres.name}"
}

output "DISCOURSE_DB_PASSWORD" {
  value = "${aws_db_instance.discourse_postgres.password}"
}

output "DISCOURSE_DB_PORT" {
  value = "${aws_db_instance.discourse_postgres.port}"
}

output "DISCOURSE_DB_USERNAME" {
  value = "${aws_db_instance.discourse_postgres.username}"
}

output "DISCOURSE_DEVELOPER_EMAILS" {
  value = "${var.DISCOURSE_DEVELOPER_EMAILS}"
}

output "DISCOURSE_ALB_HOSTNAME" {
  value = "${aws_alb.discourse_alb.dns_name}"
}

output "DISCOURSE_HOSTNAME" {
  value = "${aws_instance.discourse_app.public_dns}"
}

output "DISCOURSE_REDIS_HOST" {
  value = "${aws_elasticache_cluster.discourse_redis.cache_nodes.0.address}"
}

output "DISCOURSE_REDIS_PORT" {
  value = "${aws_elasticache_cluster.discourse_redis.port}"
}

output "DISCOURSE_SMTP_ADDRESS" {
  value = "${var.DISCOURSE_SMTP_ADDRESS}"
}

output "DISCOURSE_SMTP_PASSWORD" {
  value = "${var.DISCOURSE_SMTP_PASSWORD}"
}

output "DISCOURSE_SMTP_PORT" {
  value = "${var.DISCOURSE_SMTP_PORT}"
}

output "DISCOURSE_SMTP_USER_NAME" {
  value = "${var.DISCOURSE_SMTP_USER_NAME}"
}

output "LETSENCRYPT_ACCOUNT_EMAIL" {
  value = "${var.LETSENCRYPT_ACCOUNT_EMAIL}"
}

output "default_security_group_id" {
  value = "${aws_instance.discourse_app.vpc_security_group_ids[0]}"
}

output "PGHOST" {
  value = "${aws_db_instance.discourse_postgres.address}"
}

output "PGDATABASE" {
  value = "${aws_db_instance.discourse_postgres.name}"
}

output "PGPASSWORD" {
  value = "${aws_db_instance.discourse_postgres.password}"
}

output "PGUSER" {
  value = "${aws_db_instance.discourse_postgres.username}"
}
