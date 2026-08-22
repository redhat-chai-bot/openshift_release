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

log_step "Validating SNO cluster prerequisites for topology transition"

# Verify control plane topology is SingleReplica
log "Checking current control plane topology..."
CP_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
if [[ "${CP_TOPOLOGY}" != "SingleReplica" ]]; then
    log "ERROR: Control plane topology is '${CP_TOPOLOGY}', expected 'SingleReplica'"
    exit 1
fi
log "Control plane topology is SingleReplica - OK"

# Verify there is exactly one control-plane node
log "Checking control-plane node count..."
CP_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/control-plane -o name --no-headers | wc -l)
if [[ "${CP_NODE_COUNT}" -ne 1 ]]; then
    log "ERROR: Expected 1 control-plane node, found ${CP_NODE_COUNT}"
    exit 1
fi
log "Found ${CP_NODE_COUNT} control-plane node - OK"

# Record the original SNO node name for later reference
SNO_NODE=$(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
log "Original SNO node: ${SNO_NODE}"
echo "${SNO_NODE}" > "${SHARED_DIR}/sno-original-node"

# Verify all cluster operators are available
log_step "Checking cluster operator health"
DEGRADED_OPS=$(oc get clusteroperators -o json | \
    jq -r '.items[] | select(.status.conditions[] | select(.type=="Degraded" and .status=="True")) | .metadata.name')
if [[ -n "${DEGRADED_OPS}" ]]; then
    log "ERROR: The following cluster operators are degraded:"
    echo "${DEGRADED_OPS}"
    exit 1
fi
log "No degraded cluster operators - OK"

UNAVAILABLE_OPS=$(oc get clusteroperators -o json | \
    jq -r '.items[] | select(.status.conditions[] | select(.type=="Available" and .status=="False")) | .metadata.name')
if [[ -n "${UNAVAILABLE_OPS}" ]]; then
    log "ERROR: The following cluster operators are unavailable:"
    echo "${UNAVAILABLE_OPS}"
    exit 1
fi
log "All cluster operators are available - OK"

# Verify etcd health
log_step "Checking etcd cluster health"
ETCD_MEMBER_COUNT=$(oc get etcd cluster -o jsonpath='{.status.members}' 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
log "Etcd member count: ${ETCD_MEMBER_COUNT}"

# Display cluster info for debugging
log_step "Cluster information summary"
oc get nodes -o wide
echo ""
oc get clusterversion
echo ""
oc get infrastructure cluster -o yaml

log_step "SNO cluster pre-check passed - ready for topology transition"
