#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

log "Installing Docker, Compose plugin, and deploy helpers"
dnf update -y
dnf install -y docker docker-compose-plugin jq tar gzip unzip awscli

log "Ensuring Docker and SSM agent are running"
systemctl enable --now docker
systemctl enable --now amazon-ssm-agent || true

log "Preparing runtime directories"
install -d -m 0755 /opt/medrag/app/releases
install -d -m 0755 /opt/medrag/data/qdrant
install -d -m 0755 /opt/medrag/data/medrag
install -d -m 0755 /opt/medrag/runtime

if id ec2-user >/dev/null 2>&1; then
  usermod -aG docker ec2-user || true
  chown -R ec2-user:ec2-user /opt/medrag
fi

docker --version
docker compose version
log "Bootstrap complete"
