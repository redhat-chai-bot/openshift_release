#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

TMPDIR=""
cleanup() {
  if [ -n "${TMPDIR}" ] && [ -d "${TMPDIR}" ]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT

if [ ! -f "${SHARED_DIR}/OMR_HOST_NAME" ]; then
  echo "OMR_HOST_NAME not found in SHARED_DIR, skipping OMR log gathering"
  exit 0
fi

OMR_HOST_NAME="$(< "${SHARED_DIR}/OMR_HOST_NAME")"
if [ -z "${OMR_HOST_NAME}" ]; then
  echo "OMR_HOST_NAME is empty, skipping OMR log gathering"
  exit 0
fi

if [ ! -f "${SHARED_DIR}/terraform.tgz" ]; then
  echo "terraform.tgz not found in SHARED_DIR, cannot retrieve SSH key"
  exit 0
fi

# Extract the SSH private key from the terraform archive
TMPDIR=$(mktemp -d)
tar -xzf "${SHARED_DIR}/terraform.tgz" -C "${TMPDIR}" quaybuilder
SSH_KEY="${TMPDIR}/quaybuilder"
chmod 600 "${SSH_KEY}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o ConnectionAttempts=3"
SSH_USER="ec2-user"

echo "Gathering OMR logs from ${OMR_HOST_NAME}..."

# Container status
ssh ${SSH_OPTS} -i "${SSH_KEY}" ${SSH_USER}@"${OMR_HOST_NAME}" \
  "sudo podman ps -a" > "${ARTIFACT_DIR}/omr-podman-ps.log" 2>&1 || true

# Quay application logs
ssh ${SSH_OPTS} -i "${SSH_KEY}" ${SSH_USER}@"${OMR_HOST_NAME}" \
  "sudo podman logs --tail 50000 quay-app 2>&1" > "${ARTIFACT_DIR}/omr-quay-app.log" 2>&1 || true

# PostgreSQL logs
ssh ${SSH_OPTS} -i "${SSH_KEY}" ${SSH_USER}@"${OMR_HOST_NAME}" \
  "sudo podman logs --tail 10000 quay-postgres 2>&1" > "${ARTIFACT_DIR}/omr-quay-postgres.log" 2>&1 || true

# Redis logs
ssh ${SSH_OPTS} -i "${SSH_KEY}" ${SSH_USER}@"${OMR_HOST_NAME}" \
  "sudo podman logs --tail 10000 quay-redis 2>&1" > "${ARTIFACT_DIR}/omr-quay-redis.log" 2>&1 || true

# Systemd journal for quay-app
ssh ${SSH_OPTS} -i "${SSH_KEY}" ${SSH_USER}@"${OMR_HOST_NAME}" \
  "sudo journalctl -u quay-app --no-pager" > "${ARTIFACT_DIR}/omr-quay-app-journal.log" 2>&1 || true

# Systemd journal for quay-postgres
ssh ${SSH_OPTS} -i "${SSH_KEY}" ${SSH_USER}@"${OMR_HOST_NAME}" \
  "sudo journalctl -u quay-postgres --no-pager" > "${ARTIFACT_DIR}/omr-quay-postgres-journal.log" 2>&1 || true

# Systemd journal for quay-redis
ssh ${SSH_OPTS} -i "${SSH_KEY}" ${SSH_USER}@"${OMR_HOST_NAME}" \
  "sudo journalctl -u quay-redis --no-pager" > "${ARTIFACT_DIR}/omr-quay-redis-journal.log" 2>&1 || true

# System stats: memory, disk, uptime
ssh ${SSH_OPTS} -i "${SSH_KEY}" ${SSH_USER}@"${OMR_HOST_NAME}" \
  "free -m && df -m && uptime" > "${ARTIFACT_DIR}/omr-system-stats.log" 2>&1 || true

# Listening ports
ssh ${SSH_OPTS} -i "${SSH_KEY}" ${SSH_USER}@"${OMR_HOST_NAME}" \
  "sudo ss -tlnp" > "${ARTIFACT_DIR}/omr-connections.log" 2>&1 || true

echo "OMR log gathering complete."
