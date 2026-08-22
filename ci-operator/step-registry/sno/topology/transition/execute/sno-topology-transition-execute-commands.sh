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

ADDITIONAL_CP_COUNT="${ADDITIONAL_CONTROL_PLANE_COUNT:-2}"
TARGET_CP_COUNT=$((1 + ADDITIONAL_CP_COUNT))

log_step "Initiating SNO to HA Compact topology transition"
log "Target control-plane node count: ${TARGET_CP_COUNT}"

# Get the current platform type
PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')
log "Platform: ${PLATFORM}"

# Find or identify the control-plane MachineSet
log_step "Locating control-plane MachineSet"

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
    log "No existing control-plane MachineSet found, looking for worker MachineSet to clone..."

    # On some platforms, we may need to create a control-plane MachineSet
    WORKER_MS=$(oc get machinesets -n openshift-machine-api \
        -o jsonpath='{.items[0].metadata.name}')

    if [[ -z "${WORKER_MS}" ]]; then
        log "ERROR: No MachineSets found in openshift-machine-api namespace"
        oc get machinesets -n openshift-machine-api
        exit 1
    fi

    log "Using worker MachineSet '${WORKER_MS}' as template for control-plane MachineSet"

    CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
    NEW_MS_NAME="${CLUSTER_NAME}-control-plane-0"

    # Export the worker MachineSet as a template
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

    log "Creating control-plane MachineSet..."
    oc apply -f "${SHARED_DIR}/control-plane-machineset.json"
    CONTROL_PLANE_MS="${NEW_MS_NAME}"
else
    log "Found control-plane MachineSet: ${CONTROL_PLANE_MS}"
    CURRENT_REPLICAS=$(oc get machineset "${CONTROL_PLANE_MS}" -n openshift-machine-api \
        -o jsonpath='{.spec.replicas}')
    log "Current replicas: ${CURRENT_REPLICAS}, scaling to: ${TARGET_CP_COUNT}"

    oc scale machineset "${CONTROL_PLANE_MS}" -n openshift-machine-api \
        --replicas="${TARGET_CP_COUNT}"
fi

# Save the MachineSet name for subsequent steps
echo "${CONTROL_PLANE_MS}" > "${SHARED_DIR}/control-plane-machineset-name"

log_step "Waiting for machines to be provisioned"

# Wait for machines to appear
TIMEOUT=1200
INTERVAL=30
ELAPSED=0
while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
    MACHINE_COUNT=$(oc get machines -n openshift-machine-api \
        -l "machine.openshift.io/cluster-api-machine-role in (master,control-plane)" \
        --no-headers 2>/dev/null | wc -l)

    if [[ "${MACHINE_COUNT}" -ge "${TARGET_CP_COUNT}" ]]; then
        log "Found ${MACHINE_COUNT} control-plane machines"
        break
    fi

    log "Waiting for control-plane machines... (${MACHINE_COUNT}/${TARGET_CP_COUNT}, ${ELAPSED}s elapsed)"
    sleep ${INTERVAL}
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
    log "ERROR: Timed out waiting for control-plane machines to be created"
    oc get machines -n openshift-machine-api
    exit 1
fi

# Wait for machines to reach Running phase
log_step "Waiting for machines to reach Running phase"
oc wait machines -n openshift-machine-api \
    -l "machine.openshift.io/cluster-api-machine-role in (master,control-plane)" \
    --for=jsonpath='{.status.phase}'=Running \
    --timeout=30m || {
    log "ERROR: Machines did not reach Running phase"
    oc get machines -n openshift-machine-api -o wide
    exit 1
}

# Wait for nodes to be Ready
log_step "Waiting for control-plane nodes to be Ready"
oc wait nodes \
    -l 'node-role.kubernetes.io/control-plane' \
    --for=condition=Ready \
    --timeout=15m || {
    log "ERROR: Control-plane nodes did not become Ready"
    oc get nodes -l 'node-role.kubernetes.io/control-plane' -o wide
    exit 1
}

log "Control-plane nodes:"
oc get nodes -l 'node-role.kubernetes.io/control-plane' -o wide

log_step "Topology transition execution completed - nodes provisioned"
