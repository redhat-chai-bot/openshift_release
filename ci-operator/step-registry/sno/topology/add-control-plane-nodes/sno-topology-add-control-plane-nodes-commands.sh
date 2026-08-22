#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Adding control-plane nodes for SNO to HA Compact transition"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

ADDITIONAL_CP_COUNT="${ADDITIONAL_CONTROL_PLANE_COUNT:-2}"
TARGET_CP_COUNT=$((1 + ADDITIONAL_CP_COUNT))

echo "$(date -u --rfc-3339=seconds) - Target control-plane node count: ${TARGET_CP_COUNT}"

# Find the control-plane MachineSet
CONTROL_PLANE_MS=""
for ms in $(oc get machinesets -n openshift-machine-api -o jsonpath='{.items[*].metadata.name}'); do
    ROLE=$(oc get machineset "${ms}" -n openshift-machine-api \
        -o jsonpath='{.spec.template.metadata.labels.machine\.openshift\.io/cluster-api-machine-role}')
    if [[ "${ROLE}" == "master" || "${ROLE}" == "control-plane" ]]; then
        CONTROL_PLANE_MS="${ms}"
        break
    fi
done

if [[ -z "${CONTROL_PLANE_MS}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - No control-plane MachineSet found, creating one from worker template"

    WORKER_MS=$(oc get machinesets -n openshift-machine-api -o jsonpath='{.items[0].metadata.name}')
    if [[ -z "${WORKER_MS}" ]]; then
        echo "ERROR: No MachineSets found"
        oc get machinesets -n openshift-machine-api
        exit 1
    fi

    CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
    NEW_MS_NAME="${CLUSTER_NAME}-control-plane-0"

    oc get machineset "${WORKER_MS}" -n openshift-machine-api -o json | \
        jq --arg name "${NEW_MS_NAME}" --arg count "${TARGET_CP_COUNT}" '
        del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
            .metadata.generation, .status) |
        .metadata.name = $name |
        .spec.replicas = ($count | tonumber) |
        .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name |
        .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name |
        .spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"] = "master" |
        .spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-type"] = "master"
        ' > "${SHARED_DIR}/control-plane-machineset.json"

    oc apply -f "${SHARED_DIR}/control-plane-machineset.json"
    CONTROL_PLANE_MS="${NEW_MS_NAME}"
else
    echo "$(date -u --rfc-3339=seconds) - Found control-plane MachineSet: ${CONTROL_PLANE_MS}"
    CURRENT_REPLICAS=$(oc get machineset "${CONTROL_PLANE_MS}" -n openshift-machine-api \
        -o jsonpath='{.spec.replicas}')
    echo "$(date -u --rfc-3339=seconds) - Scaling from ${CURRENT_REPLICAS} to ${TARGET_CP_COUNT}"
    oc scale machineset "${CONTROL_PLANE_MS}" -n openshift-machine-api --replicas="${TARGET_CP_COUNT}"
fi

echo "${CONTROL_PLANE_MS}" > "${SHARED_DIR}/control-plane-machineset-name"

# Wait for machines to reach Running phase
echo "$(date -u --rfc-3339=seconds) - Waiting for control-plane machines to reach Running phase"
TIMEOUT=1200
INTERVAL=30
ELAPSED=0
while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
    RUNNING_COUNT=$(oc get machines -n openshift-machine-api \
        -l "machine.openshift.io/cluster-api-machine-role in (master,control-plane)" \
        -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c "Running" || true)
    if [[ "${RUNNING_COUNT}" -ge "${TARGET_CP_COUNT}" ]]; then
        echo "$(date -u --rfc-3339=seconds) - All ${RUNNING_COUNT} control-plane machines are Running"
        break
    fi
    echo "$(date -u --rfc-3339=seconds) - Running machines: ${RUNNING_COUNT}/${TARGET_CP_COUNT} (${ELAPSED}s elapsed)"
    sleep ${INTERVAL}
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
    echo "ERROR: Timed out waiting for control-plane machines"
    oc get machines -n openshift-machine-api -o wide
    exit 1
fi

# Wait for nodes to be Ready
echo "$(date -u --rfc-3339=seconds) - Waiting for control-plane nodes to be Ready"
oc wait nodes -l 'node-role.kubernetes.io/control-plane' \
    --for=condition=Ready --timeout=15m || {
    echo "ERROR: Control-plane nodes did not become Ready"
    oc get nodes -l 'node-role.kubernetes.io/control-plane' -o wide
    exit 1
}

oc get nodes -l 'node-role.kubernetes.io/control-plane' -o wide

echo "$(date -u --rfc-3339=seconds) - Control-plane nodes added successfully"
