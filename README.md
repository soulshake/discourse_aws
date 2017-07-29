# Discourse on AWS

This repository contains a Terraform plan and helper script for setting up Discourse on AWS, using AWS resources for Postgres and Redis.

## Setup

### Dependencies

- Terraform ([installation instructions](https://www.terraform.io/intro/getting-started/install.html) | [download](https://www.terraform.io/downloads.html))
- AWS CLI ([installation instructions](http://docs.aws.amazon.com/cli/latest/userguide/installing.html))
- ssh
- scp

### Setup

Upload your public key to IAM and note the name.

Copy the [secrets template](/terraform.tfvars.example):

`$ cp terraform.tfvars.example terraform.tfvars`

In this file, enter:

- your public key name as uploaded to IAM
- database credentials of your choice:
  - `DISCOURSE_DB_PASSWORD`
- your SMTP credentials:
  - `DISCOURSE_SMTP_ADDRESS`
  - `DISCOURSE_SMTP_USER_NAME`
  - `DISCOURSE_SMTP_PASSWORD`
  - `DISCOURSE_SMTP_PORT`
- your CloudFlare credentials
  - `cloudflare_email`
  - `cloudflare_token` (API key)
- the name of a public key that has been uploaded to EC2 (verify with `aws ec2 describe-key-pairs --key-name your-key-name`). This is only needed in order to manually bootstrap the instances.

Specify a `domain` (registered in Route53) in `terraform.tfvars` for DNS entries to be created automatically at CloudFlare and Route53. In the Route53 console, manually configure the domain to use CloudFlare's nameservers (as they appear in your CloudFlare account).

See the **VARIABLES** section in [`discourse.tf`](/discourse.tf) for the full list of configurable variables.

### Shared state

Modify `backend_config.tf` to refer to a `bucket` and `dynamodb_table` to be used for remote state file storage and locking. (See `utils.sh` for helper commands to create the s3 bucket and DynamoDB table if needed.)

## Usage

Complete the steps described in the **Setup** section above before proceeding.

First, run `terraform plan` to show the AWS resources that will be created.

Run `terraform apply` to create the resources.

As soon as the resources have been created, run `./spin-aws.sh`. This will:

- create two new local files, `.env` and `aws.yml`
- copy them to the running hosts you've just created
- bootstrap the hosts (by running `ssh ubuntu@$host "/var/discourse/launcher bootstrap aws && /var/discourse/launcher start aws"`)

Once bootstrap is complete, your Discourse installation should be visible at the load balancer's public DNS endpoint, visible by running `terraform output DISCOURSE_ALB_HOSTNAME`.

Note that the instances won't pass autoscaling health checks until they've been bootstrapped. This should be fixed in the near future with a real custom AMI that passes health checks on its own.

### Deleting (or replacing) resources

To destroy all resources managed by Terraform, run `terraform destroy`.
