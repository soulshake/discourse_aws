#!/bin/bash
#
# This scripts creates AWS resources and prepares them for use with Discourse
#
# Usage:
# ./spin-aws.sh
#
# Be sure to modify terraform.tfvars
# For details, see README.md

set -e
. utils.sh

DEPENDENCIES="
    aws
    ssh
    terraform
    "

greet() {
    hello=$(aws iam get-user --query 'User.UserName')
    echo "Greetings, $hello/${USER}!"
}


make_env() {
    envvars="
        DISCOURSE_DB_HOST
        DISCOURSE_DB_NAME
        DISCOURSE_DB_PASSWORD
        DISCOURSE_DB_PORT
        DISCOURSE_DB_USERNAME
        DISCOURSE_DEVELOPER_EMAILS
        DISCOURSE_HOSTNAME
        DISCOURSE_REDIS_PORT
        DISCOURSE_REDIS_HOST
        DISCOURSE_SMTP_ADDRESS
        DISCOURSE_SMTP_PORT
        DISCOURSE_SMTP_USER_NAME
        DISCOURSE_SMTP_PASSWORD
        LETSENCRYPT_ACCOUNT_EMAIL
        PGHOST
        PGDATABASE
        PGUSER
        PGPASSWORD
    "
    for ev in $envvars; do
        echo "export ${ev}=$(terraform output ${ev})"
    done
}

check_ssh() {
    host="$1"
    ssh "ubuntu@${host}" "ls /var/discourse"
}

copy_config_to_host() {
    host="$1"
    echo "** Copying files to $host..."
    scp .env "ubuntu@${host}:/tmp/.env"
    scp aws.yml "ubuntu@${host}:/var/discourse/containers/"
    ssh ubuntu@${host} "echo '[ -e /tmp/.env ] && source /tmp/.env' >> /home/ubuntu/.bashrc"
}

bootstrap_host() {
    host="$1"
    echo "** Bootstrapping $host..."
    ssh ubuntu@${host} "/var/discourse/launcher bootstrap aws && /var/discourse/launcher start aws" 
}

greet
check_dependencies || exit 1
check_envvars || exit 1

make_env > .env
echo "Wrote secrets to .env"
(
    source .env
    ./make-aws-yml.sh > aws.yml
)
echo "Wrote config to aws.yml"

for host in $(running_instances_by_asg); do
    while ! check_ssh "$host"; do
        echo "Host $host isn't reachable or hasn't finished execution of userdata.sh yet; skipping"
        break
    done

    echo "** Copying files to $host..."
    copy_config_to_host $host

    echo "** Bootstrapping $host..."
    bootstrap_host $host
done
