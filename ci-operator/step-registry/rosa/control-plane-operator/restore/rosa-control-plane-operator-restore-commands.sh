#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

if [[ ! -f "${MC_KUBECONFIG}" ]]; then
  echo "No MC kubeconfig found, skipping restore"
  exit 0
fi

HCP_NS_FILE="${SHARED_DIR}/cpo-hcp-namespace"
if [[ ! -f "${HCP_NS_FILE}" ]]; then
  echo "No HCP namespace file found, deploy may not have completed. Skipping restore."
  exit 0
fi
HCP_NS=$(cat "${HCP_NS_FILE}")

HC_NS_FILE="${SHARED_DIR}/cpo-hc-namespace"
HC_NAME_FILE="${SHARED_DIR}/cpo-hc-name"
HC_NS=""
HC_NAME=""
if [[ -f "${HC_NS_FILE}" && -f "${HC_NAME_FILE}" ]]; then
  HC_NS=$(cat "${HC_NS_FILE}")
  HC_NAME=$(cat "${HC_NAME_FILE}")
fi

ORIGINAL_IMAGE_FILE="${SHARED_DIR}/cpo-original-image"
if [[ ! -f "${ORIGINAL_IMAGE_FILE}" ]]; then
  echo "No original CPO image file found, deploy may not have completed. Skipping restore."
  exit 0
fi

ORIGINAL_IMAGE=$(cat "${ORIGINAL_IMAGE_FILE}")
echo "Restoring CPO to original image: ${ORIGINAL_IMAGE}"

# Remove the CPO image annotation from the HostedCluster CR so the HO
# resumes using its default CPO image during reconciliation
if [[ -n "${HC_NS}" && -n "${HC_NAME}" ]]; then
  echo "Removing control-plane-operator-image annotation from HostedCluster ${HC_NS}/${HC_NAME}..."
  KUBECONFIG="${MC_KUBECONFIG}" oc annotate hostedcluster -n "${HC_NS}" "${HC_NAME}" \
    "hypershift.openshift.io/control-plane-operator-image-" --overwrite 2>/dev/null || true
else
  echo "WARNING: HostedCluster namespace/name not found, skipping annotation removal"
fi

# Restore the original CPO image
KUBECONFIG="${MC_KUBECONFIG}" oc set image deployment/control-plane-operator -n "${HCP_NS}" \
  control-plane-operator="${ORIGINAL_IMAGE}"

# Remove ci-cpo-registry-pull from deployment imagePullSecrets, preserving other entries
UPDATED_SECRETS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment control-plane-operator -n "${HCP_NS}" -o json \
  | jq -c '[.spec.template.spec.imagePullSecrets // [] | .[] | select(.name != "ci-cpo-registry-pull")]')
KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment control-plane-operator -n "${HCP_NS}" --type=merge \
  -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":${UPDATED_SECRETS}}}}}" 2>/dev/null || true

# Delete the CI registry pull secret
KUBECONFIG="${MC_KUBECONFIG}" oc delete secret ci-cpo-registry-pull -n "${HCP_NS}" --ignore-not-found

# Wait for rollout
echo "Waiting for CPO rollout..."
KUBECONFIG="${MC_KUBECONFIG}" oc rollout status deployment/control-plane-operator -n "${HCP_NS}" --timeout=300s

DEPLOYED_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment control-plane-operator -n "${HCP_NS}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="control-plane-operator")].image}')
echo "Restored CPO image: ${DEPLOYED_IMAGE}"

echo "Control-plane-operator restored successfully"
