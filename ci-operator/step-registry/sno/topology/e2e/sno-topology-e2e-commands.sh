#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Running e2e tests on post-transition HA Compact cluster"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Verify the cluster is in HA topology before running tests
CP_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
echo "$(date -u --rfc-3339=seconds) - Control plane topology: ${CP_TOPOLOGY}"

CP_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l)
echo "$(date -u --rfc-3339=seconds) - Control-plane nodes: ${CP_NODE_COUNT}"

if [[ "${CP_TOPOLOGY}" != "HighlyAvailable" ]]; then
    echo "WARNING: Control plane topology is '${CP_TOPOLOGY}', expected 'HighlyAvailable'"
fi

# Build test arguments
TEST_ARGS="--max-parallel-tests 30"

if [[ -n "${TEST_SKIPS:-}" ]]; then
    GREP_FILTER=$(echo "${TEST_SKIPS}" | sed 's/[[:space:]]*|[[:space:]]*/\\n/g')
    TEST_ARGS="${TEST_ARGS} --skip-matching '${GREP_FILTER}'"
fi

echo "$(date -u --rfc-3339=seconds) - Running test suite: ${TEST_SUITE}"
echo "$(date -u --rfc-3339=seconds) - Test args: ${TEST_ARGS}"

# Run the e2e test suite
set +e
openshift-tests run "${TEST_SUITE}" \
    ${TEST_ARGS} \
    -o "${ARTIFACT_DIR}/e2e.log" \
    --junit-dir="${ARTIFACT_DIR}/junit" 2>&1 | tee "${ARTIFACT_DIR}/openshift-tests.log"
TEST_EXIT=$?
set -e

echo "$(date -u --rfc-3339=seconds) - Test suite finished with exit code: ${TEST_EXIT}"

# Dump cluster state for debugging if tests failed
if [[ ${TEST_EXIT} -ne 0 ]]; then
    echo "$(date -u --rfc-3339=seconds) - Collecting debug information after test failure"
    oc get nodes -o wide || true
    oc get clusteroperators || true
    oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | head -50 || true
fi

exit ${TEST_EXIT}
