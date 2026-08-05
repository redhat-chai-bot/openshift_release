#!/bin/bash
set -euo pipefail

ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"
STORAGE_CLUSTER_NAME="${STORAGE_CLUSTER_NAME:-ocs-storagecluster}"
TEST_PVC_TIMEOUT="${TEST_PVC_TIMEOUT:-30}"

JUNIT_FILE="${ARTIFACT_DIR}/junit_odf_health.xml"

failures=0
total=0
test_results=""

record_result() {
  local name="$1" passed="$2" msg="${3:-}"
  (( total++ )) || true
  if [[ "${passed}" == "true" ]]; then
    test_results+=" <testcase classname=\"odf-health\" name=\"${name}\"/>\n"
  else
    (( failures++ )) || true
    test_results+=" <testcase classname=\"odf-health\" name=\"${name}\"><failure message=\"${msg}\"/></testcase>\n"
  fi
}

collect_diagnostics() {
  oc get storagecluster -n "${ODF_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/storagecluster.yaml" 2>/dev/null || true
  oc get cephcluster -n "${ODF_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/cephcluster.yaml" 2>/dev/null || true
  oc get sc -o yaml > "${ARTIFACT_DIR}/storageclasses.yaml" 2>/dev/null || true
  oc get pods -n "${ODF_NAMESPACE}" -o wide > "${ARTIFACT_DIR}/odf-pods.txt" 2>/dev/null || true
}
trap collect_diagnostics EXIT

sc_phase=$(oc get storagecluster "${STORAGE_CLUSTER_NAME}" -n "${ODF_NAMESPACE}" -o jsonpath='{ .status.phase}' 2>/dev/null) || sc_phase=""
if [[ "${sc_phase}" == "Ready" ]]; then
  record_result "storagecluster-ready" "true"
else
  record_result "storagecluster-ready" "false" "StorageCluster phase is '${sc_phase:-NOT_FOUND}', expected 'Ready'"
fi

ceph_health=$(oc get cephcluster -n "${ODF_NAMESPACE}" -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null) || ceph_health=""
if [[ "${ceph_health}" == "HEALTH_OK" || "${ceph_health}" == "HEALTH_WARN" ]]; then
  record_result "cephcluster-healthy" "true"
else
  record_result "cephcluster-healthy" "false" "CephCluster health is '${ceph_health:-NOT_FOUND}', expected HEALTH_OK or HEALTH_WARN"
fi

sc_list=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || sc_list=""
for required_sc in ocs-storagecluster-ceph-rbd ocs-storagecluster-cephfs; do
  if echo "${sc_list}" | grep -qw "${required_sc}"; then
    record_result "storageclass-${required_sc}" "true"
  else
    record_result "storageclass-${required_sc}" "false" "StorageClass ${required_sc} not found"
  fi
done

test_pvc_name="odf-health-check-$$"
oc apply -n "${ODF_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${test_pvc_name}
  namespace: ${ODF_NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ocs-storagecluster-ceph-rbd
  resources:
    requests:
      storage: 1Gi
EOF

pvc_bound="false"
elapsed=0
while [[ ${elapsed} -lt ${TEST_PVC_TIMEOUT} ]]; do
  phase=$(oc get pvc "${test_pvc_name}" -n "${ODF_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null) || phase=""
  if [[ "${phase}" == "Bound" ]]; then
    pvc_bound="true"
    break
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

oc delete pvc "${test_pvc_name}" -n "${ODF_NAMESPACE}" --ignore-not-found --wait=false

if [[ "${pvc_bound}" == "true" ]]; then
  record_result "pvc-bind-ceph-rbd" "true"
else
  record_result "pvc-bind-ceph-rbd" "false" "PVC did not bind within ${TEST_PVC_TIMEOUT}s (phase: ${phase:-unknown})"
fi

cat > "${JUNIT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="odf-health" tests="${total}" failures="${failures}">
$(echo -e "${test_results}")
</testsuite>
EOF

if [[ ${failures} -gt 0 ]]; then
  echo "FAIL: ${failures}/${total} ODF health checks failed"
  exit 1
fi

echo "PASS: All ${total} ODF health checks passed"
