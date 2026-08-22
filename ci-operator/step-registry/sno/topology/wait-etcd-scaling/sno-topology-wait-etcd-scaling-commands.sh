#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Waiting for etcd to scale to multi-member quorum"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

EXPECTED_MEMBERS=3
TIMEOUT=1200
INTERVAL=30
ELAPSED=0

while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
    # Check etcd member count
    MEMBER_COUNT=$(oc get etcd cluster -o jsonpath='{.status.members}' 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

    # Check etcd operator conditions
    ETCD_AVAILABLE=$(oc get etcd cluster -o jsonpath='{.status.conditions}' 2>/dev/null | \
        jq -r '.[] | select(.type=="EtcdMembersAvailable") | .status' 2>/dev/null || echo "Unknown")

    ETCD_PROGRESSING=$(oc get clusteroperator etcd -o jsonpath='{.status.conditions}' 2>/dev/null | \
        jq -r '.[] | select(.type=="Progressing") | .status' 2>/dev/null || echo "Unknown")

    echo "$(date -u --rfc-3339=seconds) - Etcd members: ${MEMBER_COUNT}/${EXPECTED_MEMBERS}, available: ${ETCD_AVAILABLE}, progressing: ${ETCD_PROGRESSING} (${ELAPSED}s elapsed)"

    if [[ "${MEMBER_COUNT}" -ge "${EXPECTED_MEMBERS}" && "${ETCD_AVAILABLE}" == "True" && "${ETCD_PROGRESSING}" == "False" ]]; then
        echo "$(date -u --rfc-3339=seconds) - Etcd cluster has scaled to ${MEMBER_COUNT} members and is stable"
        break
    fi

    sleep ${INTERVAL}
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
    echo "ERROR: Timed out waiting for etcd to scale"
    oc get etcd cluster -o yaml || true
    oc get clusteroperator etcd -o yaml || true
    oc get pods -n openshift-etcd -o wide || true
    exit 1
fi

# Verify etcd pods are running on all control-plane nodes
echo "$(date -u --rfc-3339=seconds) - Verifying etcd pods"
oc get pods -n openshift-etcd -o wide

# Wait for the etcd operator to settle
echo "$(date -u --rfc-3339=seconds) - Waiting for etcd operator to be available and not degraded"
oc wait clusteroperator etcd --for=condition=Available=true --timeout=5m
oc wait clusteroperator etcd --for=condition=Degraded=false --timeout=5m

echo "$(date -u --rfc-3339=seconds) - Etcd scaling complete"
