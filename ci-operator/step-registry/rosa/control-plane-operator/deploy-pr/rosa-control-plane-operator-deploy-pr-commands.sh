#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Log in to OCM
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

if [[ -z "${CONTROL_PLANE_OPERATOR_IMAGE:-}" ]]; then
  echo "CONTROL_PLANE_OPERATOR_IMAGE is required (injected via dependencies)"
  exit 1
fi

echo "PR-built CPO image: ${CONTROL_PLANE_OPERATOR_IMAGE}"

# Read MC kubeconfig (written by rosa-cluster-credentials-hypershift-mgmt)
MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
if [[ ! -f "${MC_KUBECONFIG}" ]]; then
  echo "MC kubeconfig not found at ${MC_KUBECONFIG}"
  exit 1
fi

# Read the cluster ID (written by rosa-cluster-provision)
CLUSTER_ID_FILE="${SHARED_DIR}/cluster-id"
if [[ ! -f "${CLUSTER_ID_FILE}" ]]; then
  echo "Cluster ID file not found at ${CLUSTER_ID_FILE}"
  exit 1
fi
CLUSTER_ID=$(cat "${CLUSTER_ID_FILE}" | tr -d '[:space:]')
echo "Hosted cluster ID: ${CLUSTER_ID}"

# Discover the HCP namespace on the management cluster
echo "Discovering HCP namespace for cluster ${CLUSTER_ID}..."
HCP_NS=""

# Method 1: Look up the HostedCluster CR matching our cluster ID
HC_JSON=$(KUBECONFIG="${MC_KUBECONFIG}" oc get hostedclusters.hypershift.openshift.io -A -o json 2>/dev/null) || true
HC_INFO=""
if [[ -n "${HC_JSON}" ]]; then
  HC_INFO=$(echo "${HC_JSON}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
cid = '${CLUSTER_ID}'
for item in data.get('items', []):
    meta = item.get('metadata', {})
    name = meta.get('name', '')
    ns = meta.get('namespace', '')
    spec = item.get('spec', {})
    infra_id = spec.get('infraID', '')
    cluster_id = spec.get('clusterID', '')
    if cid in (name, infra_id, cluster_id):
        # Output: hc-namespace hc-name hcp-namespace
        print(ns + ' ' + name + ' ' + ns + '-' + name)
        break
" 2>/dev/null) || true
fi

HC_NS=""
HC_NAME=""
HCP_NS=""
if [[ -n "${HC_INFO}" ]]; then
  HC_NS=$(echo "${HC_INFO}" | awk '{print $1}')
  HC_NAME=$(echo "${HC_INFO}" | awk '{print $2}')
  HCP_NS=$(echo "${HC_INFO}" | awk '{print $3}')
fi

if [[ -z "${HCP_NS}" ]]; then
  # Method 2: Search for a namespace containing the cluster ID with label
  HCP_NS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get namespaces -l "api.openshift.com/id=${CLUSTER_ID}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
fi

if [[ -z "${HCP_NS}" ]]; then
  echo "Could not determine HCP namespace for cluster ${CLUSTER_ID}"
  exit 1
fi

if [[ -z "${HC_NS}" || -z "${HC_NAME}" ]]; then
  echo "Could not determine HostedCluster namespace/name for cluster ${CLUSTER_ID}"
  exit 1
fi

echo "HostedCluster: ${HC_NS}/${HC_NAME}"
echo "HCP namespace: ${HCP_NS}"
echo "${HC_NS}" > "${SHARED_DIR}/cpo-hc-namespace"
echo "${HC_NAME}" > "${SHARED_DIR}/cpo-hc-name"
echo "${HCP_NS}" > "${SHARED_DIR}/cpo-hcp-namespace"

# Annotate the HostedCluster CR so the HO uses the PR-built CPO image
# This prevents the HO from reverting the deployment during reconciliation
echo "Setting control-plane-operator-image annotation on HostedCluster ${HC_NS}/${HC_NAME}..."
KUBECONFIG="${MC_KUBECONFIG}" oc annotate hostedcluster -n "${HC_NS}" "${HC_NAME}" \
  "hypershift.openshift.io/control-plane-operator-image=${CONTROL_PLANE_OPERATOR_IMAGE}" \
  --overwrite

# Save current CPO image for restoration in post steps
ORIGINAL_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment control-plane-operator -n "${HCP_NS}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="control-plane-operator")].image}')
echo "${ORIGINAL_IMAGE}" > "${SHARED_DIR}/cpo-original-image"
echo "Current CPO image: ${ORIGINAL_IMAGE}"

# Extract CI registry host from the image reference
CI_REGISTRY=$(echo "${CONTROL_PLANE_OPERATOR_IMAGE}" | cut -d'/' -f1)
echo "CI registry: ${CI_REGISTRY}"

# Create a pull secret on the MC for the CI registry using the pod's SA token
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
KUBECONFIG="${MC_KUBECONFIG}" oc create secret docker-registry ci-cpo-registry-pull \
  --docker-server="${CI_REGISTRY}" \
  --docker-username=serviceaccount \
  --docker-password="${SA_TOKEN}" \
  -n "${HCP_NS}" \
  --dry-run=client -o yaml | KUBECONFIG="${MC_KUBECONFIG}" oc apply -f -
echo "Created CI registry pull secret in HCP namespace"

# Patch the CPO deployment with the PR image
echo "Deploying PR-built CPO image to HCP namespace ${HCP_NS}..."
KUBECONFIG="${MC_KUBECONFIG}" oc set image deployment/control-plane-operator -n "${HCP_NS}" \
  control-plane-operator="${CONTROL_PLANE_OPERATOR_IMAGE}"

# Add the pull secret to the deployment if not already present
EXISTING_PULL_SECRETS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment control-plane-operator -n "${HCP_NS}" \
  -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}' 2>/dev/null || echo "")
if ! echo " ${EXISTING_PULL_SECRETS} " | grep -q " ci-cpo-registry-pull "; then
  if [[ -z "${EXISTING_PULL_SECRETS}" ]]; then
    KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment control-plane-operator -n "${HCP_NS}" \
      --type=json -p '[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"ci-cpo-registry-pull"}]}]'
  else
    KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment control-plane-operator -n "${HCP_NS}" \
      --type=json -p '[{"op":"add","path":"/spec/template/spec/imagePullSecrets/-","value":{"name":"ci-cpo-registry-pull"}}]'
  fi
fi

# Wait for rollout
echo "Waiting for CPO rollout..."
KUBECONFIG="${MC_KUBECONFIG}" oc rollout status deployment/control-plane-operator -n "${HCP_NS}" --timeout=300s

DEPLOYED_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment control-plane-operator -n "${HCP_NS}" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="control-plane-operator")].image}')
echo "Deployed CPO image: ${DEPLOYED_IMAGE}"

READY_REPLICAS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment control-plane-operator -n "${HCP_NS}" \
  -o jsonpath='{.status.readyReplicas}')
echo "Ready replicas: ${READY_REPLICAS}"

if [[ "${READY_REPLICAS}" -lt 1 ]]; then
  echo "CPO deployment has no ready replicas after rollout!"
  exit 1
fi

echo "PR-built control-plane-operator successfully deployed to ${HCP_NS}"
