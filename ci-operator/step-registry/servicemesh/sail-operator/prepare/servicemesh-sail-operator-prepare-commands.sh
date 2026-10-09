#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

require_env() {
  local name=$1
  if [ -z "${!name:-}" ]; then
    echo "Required environment variable ${name} is not set" >&2
    exit 1
  fi
}

require_env SHARED_DIR
require_env MAISTRA_NAMESPACE
require_env MAISTRA_SC_POD

readonly remote_state_file=/work/sail-e2e-state.json
readonly shared_state_file="${SHARED_DIR}/sail-e2e-state.json"
readonly quay_credentials_dir="${QUAY_CREDENTIALS_DIR:-/tmp/secrets}"

apply_versions_config() {
  if [ -z "${VERSIONS_YAML_CONFIG:-}" ]; then
    return
  fi

  if [[ "${VERSIONS_YAML_CONFIG}" =~ ^export[[:space:]]+VERSIONS_YAML_FILE=([A-Za-z0-9._/-]+)[[:space:]]*\&\&[[:space:]]*$ ]]; then
    VERSIONS_YAML_FILE="${BASH_REMATCH[1]}"
    export VERSIONS_YAML_FILE
    return
  fi

  echo "VERSIONS_YAML_CONFIG only supports the documented 'export VERSIONS_YAML_FILE=<path> &&' form" >&2
  exit 1
}

normalize_architecture() {
  local architecture="${OCP_ARCH:-}"
  if [ -z "${architecture}" ]; then
    architecture=$(oc exec -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" -- uname -m)
  fi

  case "${architecture}" in
    amd64|x86_64)
      echo amd64
      ;;
    arm64|aarch64)
      echo arm64
      ;;
    *)
      echo "Unsupported test architecture: ${architecture}" >&2
      return 1
      ;;
  esac
}

apply_versions_config
target_arch=$(normalize_architecture)

if [ ! -f "${quay_credentials_dir}/username" ] || [ ! -f "${quay_credentials_dir}/password" ]; then
  echo "Quay.io credentials were not mounted" >&2
  exit 1
fi

quay_username=$(cat "${quay_credentials_dir}/username")
printf '%s' "$(cat "${quay_credentials_dir}/password")" | \
  oc exec -i -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" -- \
  docker login -u "${quay_username}" --password-stdin quay.io

echo "Preparing Sail Operator on ${target_arch} in the privileged builder pod"
oc exec -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" -- \
  env \
    KUBECONFIG=/work/ci-kubeconfig \
    BUILD_WITH_CONTAINER=0 \
    CI="${CI:-true}" \
    HUB="${HUB:-quay.io/sail-dev}" \
    USE_INTERNAL_REGISTRY=false \
    PR_NUMBER="${PULL_NUMBER:-${PR_NUMBER:-}}" \
    OLM="${OLM:-true}" \
    EXPECTED_REGISTRY="${EXPECTED_REGISTRY:-}" \
    FIPS_CLUSTER="${FIPS_CLUSTER:-false}" \
    ISTIO_VERSIONS="${ISTIO_VERSIONS:-}" \
    VERSIONS_YAML_FILE="${VERSIONS_YAML_FILE:-versions.yaml}" \
    VERSIONS_YAML_DIR="${VERSIONS_YAML_DIR:-pkg/istioversion}" \
    TARGET_ARCH="${target_arch}" \
    E2E_STATE_FILE="${remote_state_file}" \
    ARTIFACTS=/tmp/sail-e2e-preparation-artifacts \
  sh -c 'cd /work && entrypoint make test.e2e.ocp.prepare'

if ! oc exec -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" -- \
  chmod 0644 "${remote_state_file}"; then
  echo "Failed to make remote preparation state readable" >&2
  exit 1
fi

if ! oc cp \
  "${MAISTRA_NAMESPACE}/${MAISTRA_SC_POD}:${remote_state_file}" \
  "${shared_state_file}"; then
  echo "Failed to copy preparation state to ${shared_state_file}" >&2
  exit 1
fi
if ! chmod 0644 "${shared_state_file}"; then
  echo "Failed to make preparation state ${shared_state_file} readable by the test step" >&2
  exit 1
fi

if ! jq -e \
  --arg expected_olm "${OLM:-true}" \
  --arg expected_arch "${target_arch}" \
  '.schemaVersion == 1 and
   (.hub | type == "string" and length > 0) and
   (.tag | type == "string" and length > 0) and
   (.imageBase | type == "string" and length > 0) and
   (.namespace | type == "string" and length > 0) and
   (.deploymentName | type == "string" and length > 0) and
   (.olm == "true" or .olm == "false") and
   .olm == $expected_olm and
   .targetArch == $expected_arch' \
  "${shared_state_file}" >/dev/null; then
  echo "Copied preparation state ${shared_state_file} is invalid" >&2
  exit 1
fi

echo "Sail Operator preparation completed; state is available at ${shared_state_file}"
