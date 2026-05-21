#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# fips-check-tls-scan: Runs the TLS scanner from within the test cluster
# to verify TLS compliance of all pod endpoints.
#
# This step deploys the tls-scanner as a privileged pod inside the cluster
# with hostNetwork and hostPID access, then collects scan results and
# JUnit artifacts. The step fails if TLS compliance issues are detected.

NAMESPACE="fips-tls-scan-${RANDOM}"
SCANNER_IMAGE="quay.io/openshift/tls-scanner:latest"
SCANNER_ARTIFACT_DIR="${ARTIFACT_DIR}/tls-scanner"

echo "=== FIPS TLS Scanner ==="
echo "Scanner image: ${SCANNER_IMAGE}"
echo "Namespace: ${NAMESPACE}"

# Create namespace with privileged PSA labels
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
oc label namespace "${NAMESPACE}" \
    security.openshift.io/scc.podSecurityLabelSync=false \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged \
    --overwrite=true

# Cleanup on exit
cleanup() {
    echo "Cleaning up namespace ${NAMESPACE}..."
    oc delete namespace "${NAMESPACE}" --ignore-not-found --wait=false || true
}
trap cleanup EXIT

# Grant cluster-admin and privileged SCC to the default service account
oc adm policy add-cluster-role-to-user cluster-admin -z default -n "${NAMESPACE}"
oc adm policy add-scc-to-user privileged -z default -n "${NAMESPACE}"

# Wait for RBAC/SCC changes to propagate
echo "Waiting for RBAC/SCC changes to propagate..."
sleep 10

mkdir -p "${SCANNER_ARTIFACT_DIR}"

# Deploy the scanner pod with privileged access and host networking
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: tls-scanner
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: default
  restartPolicy: Never
  hostNetwork: true
  hostPID: true
  containers:
  - name: scanner
    image: ${SCANNER_IMAGE}
    command:
    - /bin/bash
    - -c
    - |
      mkdir -p /results
      /usr/local/bin/tls-scanner -j 4 --all-pods \
        --json-file /results/results.json \
        --csv-file /results/results.csv \
        --junit-file /results/junit_tls_scan.xml \
        --log-file /results/scan.log 2>&1 | tee /results/output.log
      SCAN_EXIT_CODE=\${PIPESTATUS[0]}
      echo "\${SCAN_EXIT_CODE}" > /results/exit_code
      echo "Scan complete. Exit code: \${SCAN_EXIT_CODE}" | tee -a /results/output.log
      touch /results/scan.done
      # Keep pod alive for artifact collection
      sleep 120
      exit \${SCAN_EXIT_CODE}
    resources:
      requests:
        cpu: "4"
        memory: 4Gi
      limits:
        cpu: "4"
        memory: 4Gi
    securityContext:
      privileged: true
      runAsUser: 0
    volumeMounts:
    - name: results
      mountPath: /results
  volumes:
  - name: results
    emptyDir: {}
EOF

echo "Waiting for scanner pod to start..."
oc wait --for=condition=Ready pod/tls-scanner -n "${NAMESPACE}" --timeout=5m || {
    echo "Pod failed to start:"
    oc describe pod/tls-scanner -n "${NAMESPACE}"
    oc get events -n "${NAMESPACE}"
    exit 1
}

echo "Streaming scanner logs..."
oc logs -f pod/tls-scanner -n "${NAMESPACE}" &
LOGS_PID=$!

echo "Waiting for scan to finish..."
while true; do
    phase=$(oc get pod/tls-scanner -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    # Check for scan completion marker (must copy artifacts while pod is still running)
    if oc exec pod/tls-scanner -n "${NAMESPACE}" -- test -f /results/scan.done 2>/dev/null; then
        echo "/results/scan.done found — collecting artifacts"
        break
    fi
    # Fallback: pod already exited
    if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
        echo "Warning: pod ${phase} before artifact collection"
        break
    fi
    sleep 15
done

echo "Copying artifacts..."
oc cp "${NAMESPACE}/tls-scanner:/results/." "${SCANNER_ARTIFACT_DIR}/" || echo "Warning: Failed to copy some artifacts"

# Copy JUnit XML to the top-level artifact dir for Spyglass/Prow
if [[ -f "${SCANNER_ARTIFACT_DIR}/junit_tls_scan.xml" ]]; then
    cp "${SCANNER_ARTIFACT_DIR}/junit_tls_scan.xml" "${ARTIFACT_DIR}/junit_fips-tls-scan.xml"
    echo "JUnit results copied to ${ARTIFACT_DIR}/junit_fips-tls-scan.xml"
fi

wait $LOGS_PID 2>/dev/null || true

# Determine pass/fail from the scanner exit code
scan_exit_code=0
if [[ -f "${SCANNER_ARTIFACT_DIR}/exit_code" ]]; then
    scan_exit_code=$(cat "${SCANNER_ARTIFACT_DIR}/exit_code" 2>/dev/null || echo "1")
fi

echo "=== FIPS TLS Scanner Complete ==="
echo "Scanner exit code: ${scan_exit_code}"
ls -la "${SCANNER_ARTIFACT_DIR}" || true

if [[ "${scan_exit_code}" != "0" ]]; then
    echo "TLS scanner detected compliance issues — failing step"
    exit 1
fi

echo "TLS scan passed — no compliance issues detected"
exit 0
