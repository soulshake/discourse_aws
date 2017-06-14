# Discourse on AWS

This repository contains a Terraform plan and helper script for setting up Discourse on AWS, using AWS resources for Postgres and Redis.

## Setup

### Dependencies

- Terraform ([installation instructions](https://www.terraform.io/intro/getting-started/install.html) | [download](https://www.terraform.io/downloads.html))
- AWS CLI ([installation instructions](http://docs.aws.amazon.com/cli/latest/userguide/installing.html))
- ssh
- scp

### Setup

Export environment variables containing your AWS credentials (`AWS_SECRET_ACCESS_KEY` and `AWS_ACCESS_KEY_ID`).

Copy the [secrets template](/terraform.tfvars.example):

`$ cp terraform.tfvars.example terraform.tfvars`

In this file, enter: 

- your public key (to SSH to the EC2 instance): this should match the output of `ssh-add -L | head -n1`
- database credentials of your choice:
  - `DISCOURSE_DB_PASSWORD`
- your SMTP credentials:
  - `DISCOURSE_SMTP_ADDRESS`
  - `DISCOURSE_SMTP_USER_NAME`
  - `DISCOURSE_SMTP_PASSWORD`
  - `DISCOURSE_SMTP_PORT`

See the "VARIABLES" section in [`discourse.tf`](/discourse.tf) for the full list of configurable variables.


## Usage

Complete the steps described in the **Setup** section above before proceeding.

First, run [`spin-aws.sh`](/spin-aws.sh); on the initial run, this will upload your public key to AWS (so it can be added to `authorized_keys` on the EC2 instance) and then exit.

Next, run `terraform plan` to show the AWS resources that will be created.

To actually create the EC2 instance, Postgres database and Redis, run `terraform apply`.

Then, run `./spin-aws.sh` again.  This will result in two new local files, `.env` and `aws.yml`, which should have been copied to the Discourse host for you.

Finally, to bootstrap and start, run:

`ssh ubuntu@$(terraform output DISCOURSE_HOSTNAME) "/var/discourse/launcher bootstrap aws && /var/discourse/launcher start aws"`

Once bootstrap is complete, your Discourse installation should be visible at the instance's public DNS endpoint, visible by running:

`terraform output DISCOURSE_HOSTNAME`

It should also be accessible via the load balancer endpoint (`terraform output DISCOURSE_ELB_HOSTNAME`).

## Debugging

Note: Redis and Postgres should *not* be accessible from the internet. Therefore, you first need to SSH to the Discourse host: `ssh ubuntu@$(terraform output DISCOURSE_HOSTNAME)`

### Verify Redis connectivity

`redis-cli -h $DISCOURSE_REDIS_HOST ping`  # This should work from the Discourse app instance, but not elsewhere

Also: `redis-cli -h $DISCOURSE_REDIS_HOST set mykey somevalue` followed by `get mykey` should return "somevalue".

### Verify Postgres connectivity

To check Postgres (ensure `PGUSER`, `PGHOST` and `PGPASSWORD` are set; this should be automatically sourced via the `/tmp/.env` file):

`psql -d discourse -c "select 'It is running'"`  # This should work from the Discourse app instance, but not elsewhere

### Deleting (or replacing) resources

To destroy all resources managed by Terraform, run `terraform destroy`.

Occasionally, dependencies between resources can prevent a deletion or replacement from completing successfully.

For example, if you get an error such as the following (when trying to delete a subnet, in the case below):

```
* aws_subnet.c: Error deleting subnet: timeout while waiting for state to become 'destroyed' (last state: 'pending', timeout: 5m0s)
```

...then try deleting the resource manually from the [AWS console](https://console.aws.amazon.com). Usually if Terraform fails to delete a resource, it's because AWS is preventing it for some reason. In this case, attempting to delete the subnet from the AWS VPC dashboard results in this error:

```
The following subnets contain one or more network interfaces, and cannot be deleted until those network interfaces have been deleted.
subnet-edc4c3a7
link: "Click here to view your network interfaces."
```

Clicking on the link leads to a filtered list showing the attached network interface. Trying to detach it, even with the "force" option, fails with the following error:

```
Error deleting network interface
eni-bc614bf6: You do not have permission to access the specified resource.
```

In this example, the network interface was still attached to a subnet where a Redis and Postgres database were still running. Deleting these allowed the network interface to be detached and the subnet to be deleted.
