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

DEPENDENCIES="
    aws
    ssh
    terraform
    "

ENVVARS="
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_DEFAULT_REGION
    "

die() {
    echo "$@"
    exit 1
}

check_envvars() {
    STATUS=0
    for envvar in $ENVVARS; do
        if [ -z "${!envvar}" ]; then
            echo "Please set environment variable $envvar."
            STATUS=1
            unset $envvar
        fi
    done
    return $STATUS
}

check_dependencies() {
    STATUS=0
    for dependency in $DEPENDENCIES ; do
         if ! command -v $dependency >/dev/null; then
             echo "Could not find dependency $dependency."
             STATUS=1
         fi
    done
    return $STATUS
}

get_local_public_key() {
    ssh-add -L \
        | grep -i RSA \
        | head -n1 \
        | cut -d " " -f 1-2
}

greet() {
    hello=$(aws iam get-user --query 'User.UserName')
    echo "Greetings, $hello/${USER}!"
}

sync_keys() {
    # Make sure ssh-add -l contains "RSA" to show the SSH agent is active and a key has been added.
    ssh-add -l | grep -q RSA ||
        die "ERROR: The output of \`ssh-add -l\` doesn't contain 'RSA'. You may need to:
            - generate a keypair:   ssh-keygen -t rsa -b 4096 -C \"your_email@example.com\"
            - start the SSH agent:  eval \`ssh-agent -s\`
            - add your keys:        ssh-add
       Make sure \`ssh-add -l\` shows an RSA fingerprint and try again."

    echo -n "Syncing keys to AWS... "
    AWS_KEY_NAME=discourse-dev
    if ! aws ec2 describe-key-pairs --key-name "$AWS_KEY_NAME" &> /dev/null; then
        aws ec2 import-key-pair --key-name $AWS_KEY_NAME \
            --public-key-material "$(get_local_public_key)" &> /dev/null

        if ! aws ec2 describe-key-pairs --key-name "$AWS_KEY_NAME" &> /dev/null; then
            die "Somehow, importing the key didn't work. Make sure that 'ssh-add -l | grep -i RSA | head -n1' returns an RSA key?"
        else
            echo "Imported new key $AWS_KEY_NAME."
        fi
    else
        echo "Using existing key $AWS_KEY_NAME."
    fi
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

check_and_wait_for_host() {
    host="$(terraform output DISCOURSE_HOSTNAME 2>&1 || true)"

    [[ $host == *"The output variable requested could not be found"* ]] \
        && die "ACTION NEEDED: Please run \`terraform apply\`." \
        "If you've already successfully done so, ensure \`terraform output DISCOURSE_HOSTNAME\` works and try again."

    while ! check_ssh "$host"; do
        echo "Waiting for Discourse host to be up and to complete execution of userdata.sh..."
        sleep 5
    done
}

create_state_bucket() {
    aws s3api create-bucket \
        --region "${AWS_DEFAULT_REGION}" \
        --create-bucket-configuration LocationConstraint="${AWS_DEFAULT_REGION}" \
        --bucket "discourse-terraform-tfstate"
}

create_state_db() {
    aws dynamodb create-table \
        --region "${AWS_DEFAULT_REGION}" \
        --table-name terraform_statelock \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1
}

greet
check_dependencies || exit 1
check_envvars || exit 1

sync_keys   # Upload your default SSH key to AWS if needed, to be added to each VM's authorized_keys

tf_public_key=$(terraform output public_key | cut -d " " -f 1-2)
my_key=$(get_local_public_key)
[[ "$tf_public_key" == "$my_key" ]] || die "your local public key doesn't match the one in terraform.tfvars (\`terraform output PUBLIC_KEY\`). Run 'ssh-add -L | cut -d \" \" -f 1-2' and add the resulting output to the resource 'aws_key_pair' 'discourse-dev' in discourse.tf."

# Create an s3 bucket and dynamoDB table if they don't exist already
create_state_bucket || true
create_state_db || true

check_and_wait_for_host

# Make a .env and copy it to the discourse host
make_env > .env
(
    source .env
    ./make-aws-yml.sh > aws.yml
)

host=$(terraform output DISCOURSE_HOSTNAME)
scp .env "ubuntu@${host}:/tmp/.env"
scp aws.yml "ubuntu@${host}:/var/discourse/containers/"
ssh ubuntu@${host} "echo '[ -e /tmp/.env ] && source /tmp/.env' >> /home/ubuntu/.bashrc"

echo "------- SUCCESS ------"
echo "Wrote secrets to .env and copied it to ubuntu@${host}:/tmp/.env"
echo "Wrote configuration to aws.yml and copied it to ubuntu@${host}:/var/discourse/containers/"
echo
echo "Now run:"
echo "ssh ubuntu@${host}"
echo "or:"
echo 'ssh ubuntu@$(terraform output DISCOURSE_HOSTNAME) "/var/discourse/launcher bootstrap aws && /var/discourse/launcher start aws"'
echo
echo "See README.md for further instructions"
