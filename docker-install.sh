#!/bin/bash

# Usunięcie potencjalnych istniejących instancji Dockera
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

# Instalacja Dockera
dnf -y install dnf-plugins-core
dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Tworzenie katalogu dla Dockera
mkdir -p /Docker

# Konfiguracja zmiany miejsca instalacji
cat > /etc/docker/daemon.json <<EOL
{
  "data-root": "/Docker"
}
EOL

# Uruchomienie Dockera
systemctl enable --now docker
systemctl start docker

# Wyświetlenie katalogu domowego Dockera
docker info -f '{{ .DockerRootDir}}'

# Tworzenie volume dla Portainera
docker volume create portainer_data

# Uruchomienie kontenera Portainera
docker run -d -p 8001:8000 -p 5001:9443 --name portainer --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data portainer/portainer-ce:lts

# Sprawdzenie działania kontenerów
docker container list