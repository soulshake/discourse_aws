#################
### VARIABLES ###
#################

# IMPORTANT: The variables defined below are defaults only. You should not need to edit this file directly.
# Any variable specified below can be overridden in terraform.tfvars; all credentials and other configuration should be entered there.
# If you need to change a hardcoded value in this file, consider replacing it with a variable.
# For more information, see README.md.

variable "access_key" {}
variable "secret_key" {}

variable "app_instance_type" {
  default = "t2.medium"
}

variable "PUBLIC_KEY" {}

variable "DISCOURSE_DEVELOPER_EMAILS" {}
variable "DISCOURSE_SMTP_ADDRESS" {}
variable "DISCOURSE_SMTP_USER_NAME" {}
variable "DISCOURSE_SMTP_PASSWORD" {}
variable "DISCOURSE_SMTP_PORT" {}

variable "DISCOURSE_DB_USERNAME" {}
variable "DISCOURSE_DB_PASSWORD" {}

variable "region" {}

variable "LANG" {
  default = "en_US.UTF-8"
}

variable "LETSENCRYPT_ACCOUNT_EMAIL" {
  default = "me@example.com"
}

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

data "aws_caller_identity" "current" {}

#################
### RESOURCES ###
#################

provider "aws" {
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  region     = "${var.region}"
}

resource "aws_instance" "discourse_app" {
  ami           = "${data.aws_ami.discourse_ami.id}"
  instance_type = "${var.app_instance_type}"
  key_name      = "discourse-dev"                       # Uploaded automatically under this name by ./spin-aws.sh
  user_data     = "${file("userdata.sh")}"
  subnet_id     = "${aws_subnet.a.id}"
  depends_on    = ["aws_internet_gateway.discourse_gw"]

  vpc_security_group_ids = [
    "${aws_vpc.discourse_vpc.default_security_group_id}",
    "${aws_security_group.allow_all.id}",
    "${data.aws_db_instance.database.vpc_security_groups[0]}",
  ]

  tags {
    Name   = "discourse"
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
    Name   = "discourse"
    Source = "terraform"
  }
}

resource "aws_db_subnet_group" "discourse_db_subnet_group" {
  name = "discourse"

  subnet_ids = ["${aws_subnet.a.id}", "${aws_subnet.b.id}"]

  tags {
    Name   = "discourse"
    Source = "terraform"
  }
}

resource "aws_elasticache_subnet_group" "discourse_elasticache_subnet" {
  name       = "discourse"
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
    Name   = "discourse"
    Source = "terraform"
  }
}

# Create a new load balancer. Update 'instances' if more instances need to be added.
resource "aws_elb" "discourse_elb" {
  name = "discourse-elb"

  subnets         = ["${aws_subnet.a.id}"]
  security_groups = ["${aws_vpc.discourse_vpc.default_security_group_id}", "${aws_security_group.allow_all.id}"]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  instances                   = ["${aws_instance.discourse_app.id}"]
  cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400

  tags {
    Name   = "discourse"
    Source = "terraform"
  }
}

resource "aws_internet_gateway" "discourse_gw" {
  vpc_id = "${aws_vpc.discourse_vpc.id}"

  tags {
    Name   = "discourse"
    Source = "terraform"
  }
}

resource "aws_key_pair" "discourse_dev" {
  key_name   = "discourse-dev"
  public_key = "${var.PUBLIC_KEY}"
}

resource "aws_route" "route" {
  route_table_id         = "${aws_vpc.discourse_vpc.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.discourse_gw.id}"
}

resource "aws_kms_key" "discourse_kms_key" {
  description             = "KMS key 1"
  deletion_window_in_days = 10
}

data "terraform_remote_state" "discourse_tf_state" {
  backend = "s3"

  config {
    bucket  = "discourse-terraform-tfstate-${data.aws_caller_identity.current.account_id}"
    key     = "dev/discourse.tfstate"
    region  = "${var.region}"
    encrypt = true
    logging = true

    # The ARN of a KMS Key to use for encrypting the state.
    kms_key_id = "${aws_kms_key.discourse_kms_key.arn}"

    # The name of a DynamoDB table to use for state locking and consistency. The table must have a primary key named LockID. If not present, locking will be disabled.
    dynamodb_table = "${aws_dynamodb_table.terraform_statelock.name}"
  }
}

resource "aws_dynamodb_table" "terraform_statelock" {
  name           = "terraform_statelock"
  read_capacity  = 20
  write_capacity = 20
  hash_key       = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags {
    Name        = "discourse"
    Source      = "terraform"
    Environment = "dev"
  }
}

resource "aws_s3_bucket" "discourse_tf_state_bucket" {
  bucket = "discourse-terraform-tfstate-${data.aws_caller_identity.current.account_id}"

  acl = "private"

  versioning {
    enabled = true
  }

  logging {
    target_bucket = "${aws_s3_bucket.discourse_log_bucket.id}"
    target_prefix = "log/terraform/"
  }

  tags {
    Name        = "discourse"
    Source      = "terraform"
    Environment = "dev"
  }
}

resource "aws_s3_bucket" "discourse_log_bucket" {
  bucket = "discourse-log-bucket"
  acl    = "log-delivery-write"

  logging {
    target_bucket = "discourse-log-bucket"
    target_prefix = "log/self/"
  }

  tags {
    Name   = "discourse"
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
    Name   = "discourse"
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
    Name   = "discourse"
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
    Name   = "discourse"
    Source = "terraform"
  }
}

###############
### OUTPUTS ###
###############

# The outputs defined below can be accessed via terraform, e.g. `terraform output DISCOURSE_DB_HOST`.
# These are used to generate the .env that is copied to the Discourse host for easier setup.

output "account_id" {
  value = "${data.aws_caller_identity.current.account_id}"
}

output "caller_arn" {
  value = "${data.aws_caller_identity.current.arn}"
}

output "caller_user" {
  value = "${data.aws_caller_identity.current.user_id}"
}

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

output "DISCOURSE_ELB_HOSTNAME" {
  value = "${aws_elb.discourse_elb.dns_name}"
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

output "public_key" {
  value = "${aws_key_pair.discourse_dev.public_key}"
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
