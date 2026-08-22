#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log() {
    echo "$(date -u --rfc-3339=seconds) - $*"
}

log_step() {
    echo ""
    echo "### $* ###"
}

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

TARGET_TOPOLOGY="HighlyAvailable"

log_step "Waiting for topology transition to HighlyAvailable"

# Wait for the control plane topology to change
TIMEOUT=1800
INTERVAL=30
ELAPSED=0
while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
    CP_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}' 2>/dev/null || echo "unknown")

    if [[ "${CP_TOPOLOGY}" == "${TARGET_TOPOLOGY}" ]]; then
        log "Control plane topology is now '${TARGET_TOPOLOGY}'"
        break
    fi

    log "Current control plane topology: '${CP_TOPOLOGY}', waiting for '${TARGET_TOPOLOGY}'... (${ELAPSED}s elapsed)"
    sleep ${INTERVAL}
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
    log "ERROR: Timed out waiting for control plane topology to change to '${TARGET_TOPOLOGY}'"
    oc get infrastructure cluster -o yaml
    exit 1
fi

# Wait for etcd to form a healthy multi-member cluster
log_step "Waiting for etcd cluster to stabilize"

ETCD_TIMEOUT=600
ELAPSED=0
while [[ ${ELAPSED} -lt ${ETCD_TIMEOUT} ]]; do
    ETCD_STATUS=$(oc get etcd cluster -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")
    ETCD_AVAILABLE=$(echo "${ETCD_STATUS}" | jq -r '.[] | select(.type=="EtcdMembersAvailable") | .status' 2>/dev/null || echo "Unknown")

    if [[ "${ETCD_AVAILABLE}" == "True" ]]; then
        MEMBER_COUNT=$(oc get etcd cluster -o jsonpath='{.status.members}' 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        if [[ "${MEMBER_COUNT}" -ge 3 ]]; then
            log "Etcd cluster has ${MEMBER_COUNT} members and is available"
            break
        fi
        log "Etcd is available but only has ${MEMBER_COUNT} members, waiting for 3..."
    else
        log "Etcd members available status: ${ETCD_AVAILABLE}, waiting... (${ELAPSED}s elapsed)"
    fi

    sleep ${INTERVAL}
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ ${ELAPSED} -ge ${ETCD_TIMEOUT} ]]; then
    log "WARNING: Timed out waiting for etcd to reach 3 members, continuing..."
    oc get etcd cluster -o yaml || true
fi

# Wait for all cluster operators to reconcile
log_step "Waiting for cluster operators to reconcile after topology change"

# Wait for operators to not be progressing
log "Waiting for operators to finish progressing..."
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=20m || {
    log "WARNING: Some operators are still progressing"
    oc get clusteroperators | grep -i true || true
}

# Wait for operators to be available
log "Waiting for operators to be available..."
oc wait clusteroperators --all --for=condition=Available=true --timeout=10m || {
    log "WARNING: Some operators are not available"
    oc get clusteroperators | grep -i false || true
}

# Wait for operators to not be degraded
log "Waiting for operators to not be degraded..."
oc wait clusteroperators --all --for=condition=Degraded=false --timeout=10m || {
    log "WARNING: Some operators are degraded"
    oc get clusteroperators | grep -i true || true
}

log "Cluster operator status:"
oc get clusteroperators

log_step "Topology transition wait completed"
