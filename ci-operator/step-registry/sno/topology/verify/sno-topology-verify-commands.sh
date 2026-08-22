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

ERRORS=0

log_step "Verifying SNO to HA Compact topology transition"

# Check control plane topology
log_step "Checking control plane topology"
CP_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
if [[ "${CP_TOPOLOGY}" != "HighlyAvailable" ]]; then
    log "FAIL: Control plane topology is '${CP_TOPOLOGY}', expected 'HighlyAvailable'"
    ERRORS=$((ERRORS + 1))
else
    log "PASS: Control plane topology is HighlyAvailable"
fi

# Check infrastructure topology
INFRA_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureTopology}')
log "Infrastructure topology: ${INFRA_TOPOLOGY}"

# Check control-plane node count
log_step "Checking control-plane node count"
CP_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/control-plane -o name --no-headers | wc -l)
if [[ "${CP_NODE_COUNT}" -ne 3 ]]; then
    log "FAIL: Expected 3 control-plane nodes, found ${CP_NODE_COUNT}"
    ERRORS=$((ERRORS + 1))
else
    log "PASS: Found 3 control-plane nodes"
fi

# Check all control-plane nodes are Ready
log_step "Checking control-plane node readiness"
NOT_READY_NODES=$(oc get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' | \
    grep -v "True" || true)
if [[ -n "${NOT_READY_NODES}" ]]; then
    log "FAIL: Some control-plane nodes are not Ready:"
    echo "${NOT_READY_NODES}"
    ERRORS=$((ERRORS + 1))
else
    log "PASS: All control-plane nodes are Ready"
fi

# Check cluster operators
log_step "Checking cluster operators"
DEGRADED_OPS=$(oc get clusteroperators -o json | \
    jq -r '.items[] | select(.status.conditions[] | select(.type=="Degraded" and .status=="True")) | .metadata.name')
if [[ -n "${DEGRADED_OPS}" ]]; then
    log "FAIL: Degraded cluster operators:"
    echo "${DEGRADED_OPS}"
    ERRORS=$((ERRORS + 1))
else
    log "PASS: No degraded cluster operators"
fi

UNAVAILABLE_OPS=$(oc get clusteroperators -o json | \
    jq -r '.items[] | select(.status.conditions[] | select(.type=="Available" and .status=="False")) | .metadata.name')
if [[ -n "${UNAVAILABLE_OPS}" ]]; then
    log "FAIL: Unavailable cluster operators:"
    echo "${UNAVAILABLE_OPS}"
    ERRORS=$((ERRORS + 1))
else
    log "PASS: All cluster operators are available"
fi

# Check etcd membership
log_step "Checking etcd cluster membership"
ETCD_MEMBERS=$(oc get etcd cluster -o jsonpath='{.status.members}' 2>/dev/null | jq 'length' 2>/dev/null || echo "unknown")
if [[ "${ETCD_MEMBERS}" == "unknown" || "${ETCD_MEMBERS}" -lt 3 ]]; then
    log "FAIL: Etcd cluster has ${ETCD_MEMBERS} members, expected 3"
    ERRORS=$((ERRORS + 1))
else
    log "PASS: Etcd cluster has ${ETCD_MEMBERS} members"
fi

# Verify API server health
log_step "Checking API server health"
if ! oc get --raw /healthz &>/dev/null; then
    log "FAIL: API server health check failed"
    ERRORS=$((ERRORS + 1))
else
    log "PASS: API server is healthy"
fi

# Display final cluster state
log_step "Final cluster state"
oc get nodes -o wide
echo ""
oc get clusteroperators
echo ""
oc get infrastructure cluster -o jsonpath='{.status}' | jq .

# Summary
log_step "Topology transition verification summary"
if [[ ${ERRORS} -gt 0 ]]; then
    log "FAILED: ${ERRORS} verification check(s) failed"
    exit 1
fi

log "SUCCESS: All verification checks passed - cluster is running as HA Compact"
