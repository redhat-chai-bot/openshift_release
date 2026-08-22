#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Waiting for topology transition to HighlyAvailable"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

TARGET_TOPOLOGY="HighlyAvailable"

# Wait for the control plane topology to change
TIMEOUT=1800
INTERVAL=30
ELAPSED=0
while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
    CP_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}' 2>/dev/null || echo "unknown")
    if [[ "${CP_TOPOLOGY}" == "${TARGET_TOPOLOGY}" ]]; then
        echo "$(date -u --rfc-3339=seconds) - Control plane topology is now '${TARGET_TOPOLOGY}'"
        break
    fi
    echo "$(date -u --rfc-3339=seconds) - Current topology: '${CP_TOPOLOGY}', waiting for '${TARGET_TOPOLOGY}' (${ELAPSED}s elapsed)"
    sleep ${INTERVAL}
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
    echo "ERROR: Timed out waiting for topology to change to '${TARGET_TOPOLOGY}'"
    oc get infrastructure cluster -o yaml
    exit 1
fi

# Wait for all cluster operators to reconcile with the new topology
echo "$(date -u --rfc-3339=seconds) - Waiting for cluster operators to reconcile"

oc wait clusteroperators --all --for=condition=Progressing=false --timeout=20m || {
    echo "WARNING: Some operators still progressing"
    oc get clusteroperators
}

oc wait clusteroperators --all --for=condition=Available=true --timeout=10m || {
    echo "WARNING: Some operators not available"
    oc get clusteroperators
}

oc wait clusteroperators --all --for=condition=Degraded=false --timeout=10m || {
    echo "WARNING: Some operators degraded"
    oc get clusteroperators
}

echo "$(date -u --rfc-3339=seconds) - Cluster operator status after transition:"
oc get clusteroperators

# Verify the final state
CP_NODES=$(oc get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l)
echo "$(date -u --rfc-3339=seconds) - Control-plane nodes: ${CP_NODES}"

oc get infrastructure cluster -o jsonpath='{.status}' | jq .

echo "$(date -u --rfc-3339=seconds) - Topology transition to HighlyAvailable completed"
