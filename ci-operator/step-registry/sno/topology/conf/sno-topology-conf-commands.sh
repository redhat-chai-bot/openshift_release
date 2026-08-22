#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Capturing SNO cluster topology configuration"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Record the current control plane topology
CP_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
echo "$(date -u --rfc-3339=seconds) - Current control plane topology: ${CP_TOPOLOGY}"
if [[ "${CP_TOPOLOGY}" != "SingleReplica" ]]; then
    echo "ERROR: Expected control plane topology 'SingleReplica', got '${CP_TOPOLOGY}'"
    exit 1
fi

# Record the infrastructure topology
INFRA_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureTopology}')
echo "$(date -u --rfc-3339=seconds) - Current infrastructure topology: ${INFRA_TOPOLOGY}"

# Verify exactly one control-plane node
CP_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l)
if [[ "${CP_NODE_COUNT}" -ne 1 ]]; then
    echo "ERROR: Expected 1 control-plane node, found ${CP_NODE_COUNT}"
    exit 1
fi

# Save the original SNO node name
SNO_NODE=$(oc get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
echo "${SNO_NODE}" > "${SHARED_DIR}/sno-original-node"
echo "$(date -u --rfc-3339=seconds) - Original SNO node: ${SNO_NODE}"

# Save platform information
PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')
echo "${PLATFORM}" > "${SHARED_DIR}/sno-platform"
echo "$(date -u --rfc-3339=seconds) - Platform: ${PLATFORM}"

# Check cluster operator health before transition
echo "$(date -u --rfc-3339=seconds) - Checking cluster operator health..."
DEGRADED=$(oc get clusteroperators -o json | \
    jq -r '.items[] | select(.status.conditions[] | select(.type=="Degraded" and .status=="True")) | .metadata.name')
if [[ -n "${DEGRADED}" ]]; then
    echo "ERROR: Degraded cluster operators found: ${DEGRADED}"
    exit 1
fi

UNAVAILABLE=$(oc get clusteroperators -o json | \
    jq -r '.items[] | select(.status.conditions[] | select(.type=="Available" and .status=="False")) | .metadata.name')
if [[ -n "${UNAVAILABLE}" ]]; then
    echo "ERROR: Unavailable cluster operators found: ${UNAVAILABLE}"
    exit 1
fi

echo "$(date -u --rfc-3339=seconds) - All cluster operators healthy"

# Dump cluster state for debugging
oc get nodes -o wide
oc get clusterversion
oc get infrastructure cluster -o yaml

echo "$(date -u --rfc-3339=seconds) - SNO topology configuration captured successfully"
