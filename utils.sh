die() {
    echo "$@"
    kill -INT $$
}


create_state_bucket() {
    [ -z "$AWS_DEFAULT_REGION" ] && die "Please export AWS_DEFAULT_REGION environment variable."
    bucket_name="$1"
    [ -z "$bucket_name" ] && die "Please provide a bucket name as input, e.g. 'discourse-tfstate'."

    if ! aws s3 ls "s3://$bucket_name" &>/dev/null; then
        aws s3api create-bucket \
            --region "${AWS_DEFAULT_REGION}" \
            --create-bucket-configuration LocationConstraint="${AWS_DEFAULT_REGION}" \
            --bucket "$bucket_name"
    else
        echo "Bucket $bucket_name already exists."
    fi
}

create_state_db() {
    [ -z "$AWS_DEFAULT_REGION" ] && die "Please export AWS_DEFAULT_REGION environment variable."
    table_name="$1"
    [ -z "$table_name" ] && die "Please provide a DynamoBB table name as input, e.g. 'discourse-tfstate'."

    if ! aws dynamodb describe-table --table-name "$table_name" &> /dev/null; then
        aws dynamodb create-table \
            --region "${AWS_DEFAULT_REGION}" \
            --table-name "$table_name" \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1

        while ! aws dynamodb wait table-exists --table-name "$table_name"; do
            echo "Waiting for dyanamoDB table to finish creating..."
            sleep 5
        done
    else
        echo "Table $table_name already exists."
    fi
}

sync_keys() {
    usage="Usage: sync_keys </path/to/local/public/key> <desired key name on AWS>"
    local_key_path="$1"
    aws_key_name="$2"
    [ -z "$local_key_path" ] && die "$usage"
    [ ! -f "$local_key_path" ] && die "$local_key_path doesn't exist. Aborting."
    [ -z "$aws_key_name" ] && die "$usage"

    echo -n "Syncing keys to AWS... "
    if ! aws ec2 describe-key-pairs --key-name "$aws_key_name" &> /dev/null; then
        aws ec2 import-key-pair --key-name $aws_key_name \
            --public-key-material "$(cat $local_key_path)" &> /dev/null

        if ! aws ec2 describe-key-pairs --key-name "$aws_key_name" &> /dev/null; then
            die 'Somehow, importing the key did not work. Try running: "aws ec2 import-key-pair --key-name $aws_key_name --public-key-material "$(cat $local_key_path)"'
        else
            echo "Imported new key $aws_key_name."
        fi
    else
        echo "Using existing key $aws_key_name."
    fi
}

running_instances_by_asg() {
    asg_name_tag="discourse-terraform-ag"
    name_tag="discourse-dev-aj"
    aws ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=$name_tag" \
            "Name=tag:Source,Values=terraform" \
            "Name=tag:aws:autoscaling:groupName,Values=$asg_name_tag" \
            "Name=instance-state-name,Values=running" \
        --query \
            'Reservations[*].Instances[*].{PublicDnsName:PublicDnsName}' \
        --output text
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

check_envvars() {
    ENVVARS="
    "

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

