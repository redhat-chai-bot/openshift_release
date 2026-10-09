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
require_env ARTIFACT_DIR

readonly state_file="${SHARED_DIR}/sail-e2e-state.json"
readonly report_file="${ARTIFACT_DIR}/report.xml"

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

if [ ! -e "${state_file}" ]; then
  echo "Preparation state ${state_file} is missing; refusing to run an unprepared suite" >&2
  exit 1
fi
if [ ! -r "${state_file}" ]; then
  echo "Preparation state ${state_file} is not readable" >&2
  exit 1
fi
if [ ! -r "${SHARED_DIR}/kubeconfig" ]; then
  echo "Prepared kubeconfig ${SHARED_DIR}/kubeconfig is missing or unreadable" >&2
  exit 1
fi

expected_olm="${OLM:-true}"
if ! jq -e \
  --arg expected_olm "${expected_olm}" \
  '.schemaVersion == 1 and
   (.hub | type == "string" and length > 0) and
   (.tag | type == "string" and length > 0) and
   (.imageBase | type == "string" and length > 0) and
   (.namespace | type == "string" and length > 0) and
   (.deploymentName | type == "string" and length > 0) and
   (.targetArch == "amd64" or .targetArch == "arm64") and
   (.olm == "true" or .olm == "false") and
   .olm == $expected_olm' \
  "${state_file}" >/dev/null; then
  echo "Preparation state ${state_file} is invalid or does not match OLM=${expected_olm}" >&2
  exit 1
fi

HUB=$(jq -r '.hub' "${state_file}")
TAG=$(jq -r '.tag' "${state_file}")
IMAGE_BASE=$(jq -r '.imageBase' "${state_file}")
NAMESPACE=$(jq -r '.namespace' "${state_file}")
OLM=$(jq -r '.olm' "${state_file}")
DEPLOYMENT_NAME=$(jq -r '.deploymentName' "${state_file}")
TARGET_ARCH=$(jq -r '.targetArch' "${state_file}")

export HUB TAG IMAGE_BASE NAMESPACE OLM DEPLOYMENT_NAME TARGET_ARCH
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export ARTIFACTS="${ARTIFACT_DIR}"
export CI="${CI:-true}"
export EXPECTED_REGISTRY="${EXPECTED_REGISTRY:-}"
export FIPS_CLUSTER="${FIPS_CLUSTER:-false}"
export ISTIO_VERSIONS="${ISTIO_VERSIONS:-}"
export VERSIONS_YAML_FILE="${VERSIONS_YAML_FILE:-versions.yaml}"
export VERSIONS_YAML_DIR="${VERSIONS_YAML_DIR:-pkg/istioversion}"

apply_versions_config
mkdir -p "${ARTIFACT_DIR}"

echo "Running Sail Operator Ginkgo tests directly in the CI step container"
set +o errexit
make BUILD_WITH_CONTAINER=0 test.e2e.ocp.test-only
test_rc=$?
set -o errexit

if [ "${test_rc}" -ne 0 ]; then
  echo "=== Sail Operator diagnostic information ==="
  oc get deployment,pods -n "${NAMESPACE}" -o wide 2>/dev/null || true
  oc get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null || true
fi

if [ -f "${report_file}" ]; then
  if ! cp "${report_file}" "${SHARED_DIR}/report.xml"; then
    echo "Failed to publish JUnit report to ${SHARED_DIR}/report.xml" >&2
    if [ "${test_rc}" -eq 0 ]; then
      test_rc=1
    fi
  fi
else
  echo "Expected JUnit report ${report_file} was not generated" >&2
  if [ "${test_rc}" -eq 0 ]; then
    test_rc=1
  fi
fi

exit "${test_rc}"
