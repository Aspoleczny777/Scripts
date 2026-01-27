#!/bin/bash

# Removes existing docker instalations
dnf remove -y docker \
                docker-client \
                docker-client-latest \
                docker-common \
                docker-latest \
                docker-latest-logrotate \
                docker-logrotate \
                docker-selinux \
                docker-engine-selinux \
                docker-engine

# Installs docker
dnf -y install dnf-plugins-core
dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Makes home directory
mkdir -p /Docker

# Maps home directory
cat > /etc/docker/daemon.json <<EOL
{
  "data-root": "/Docker"
}
EOL

# Docker start
systemctl enable --now docker
systemctl start docker

# Check home dir
docker info -f '{{ .DockerRootDir}}'
