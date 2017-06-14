#!/bin/bash

apt-get update && apt-get install -yq \
    redis-tools \
    postgresql-client

wget -qO- https://get.docker.com/ | sh

usermod -aG docker ubuntu

mkdir /var/discourse
git clone https://github.com/soulshake/discourse_docker.git /var/discourse
chown -R ubuntu:ubuntu /var/discourse
