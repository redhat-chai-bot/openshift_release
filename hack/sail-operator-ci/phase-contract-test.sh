#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
sail_registry_dir="${repo_root}/ci-operator/step-registry/servicemesh/sail-operator"
prepare_script="${sail_registry_dir}/prepare/servicemesh-sail-operator-prepare-commands.sh"
test_script="${sail_registry_dir}/e2e-ocp/servicemesh-sail-operator-e2e-ocp-commands.sh"
fake_command="${repo_root}/hack/sail-operator-ci/phase-fake-command.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

mock_bin="${tmp}/bin"
mock_log="${tmp}/commands.log"
remote_state="${tmp}/remote-state.json"
password_capture="${tmp}/password"
mkdir -p "${mock_bin}"
for command in make oc cp chmod; do
  ln -s "${fake_command}" "${mock_bin}/${command}"
done

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_log() {
  local pattern=$1
  grep -Eq -- "${pattern}" "${mock_log}" || fail "missing log pattern: ${pattern}"
}

assert_no_log() {
  local pattern=$1
  if grep -Eq -- "${pattern}" "${mock_log}"; then
    fail "unexpected log pattern: ${pattern}"
  fi
}

base_env=(
  PATH="${mock_bin}:${PATH}"
  MOCK_LOG="${mock_log}"
  MOCK_REMOTE_STATE="${remote_state}"
  MOCK_PASSWORD_CAPTURE="${password_capture}"
)

write_state() {
  local file=$1
  local olm=${2:-false}
  local arch=${3:-amd64}
  printf '{"schemaVersion":1,"hub":"quay.io/sail-dev","tag":"exact-tag","imageBase":"sail-operator","namespace":"sail-operator","olm":"%s","deploymentName":"sail-operator","targetArch":"%s"}\n' \
    "${olm}" "${arch}" > "${file}"
}

run_test_step() {
  local name=$1
  local expected_rc=$2
  shift 2
  local shared="${tmp}/${name}-shared"
  local artifacts="${tmp}/${name}-artifacts"
  mkdir -p "${shared}" "${artifacts}"
  : > "${shared}/kubeconfig"
  write_state "${shared}/sail-e2e-state.json"
  : > "${mock_log}"

  set +o errexit
  env "${base_env[@]}" SHARED_DIR="${shared}" ARTIFACT_DIR="${artifacts}" \
    OLM=false "$@" bash "${test_script}"
  local rc=$?
  set -o errexit
  if [ "${rc}" -ne "${expected_rc}" ]; then
    fail "test step ${name}: expected rc ${expected_rc}, got ${rc}"
  fi
  TEST_SHARED=${shared}
  TEST_ARTIFACTS=${artifacts}
}

run_test_step success 0 MOCK_CREATE_REPORT=true
assert_log '^make BUILD_WITH_CONTAINER=0 test.e2e.ocp.test-only$'
test -f "${TEST_SHARED}/report.xml" || fail "successful suite did not publish report"

run_test_step suite-and-copy-fail 7 MOCK_CREATE_REPORT=true \
  MOCK_SUITE_RC=7 MOCK_REPORT_COPY_FAIL=true
test ! -e "${TEST_SHARED}/report.xml" || fail "failed report copy unexpectedly published"

run_test_step success-copy-fail 1 MOCK_CREATE_REPORT=true \
  MOCK_REPORT_COPY_FAIL=true
run_test_step missing-report 1 MOCK_CREATE_REPORT=false
run_test_step failed-missing-report 9 MOCK_CREATE_REPORT=false MOCK_SUITE_RC=9

# Invalid state, OLM mismatch, unsupported architecture, and a missing
# kubeconfig all fail before Make dispatch.
TEST_SHARED="${tmp}/invalid-state-shared"
TEST_ARTIFACTS="${tmp}/invalid-state-artifacts"
mkdir -p "${TEST_SHARED}" "${TEST_ARTIFACTS}"
: > "${TEST_SHARED}/kubeconfig"
printf '{"schemaVersion":99}\n' > "${TEST_SHARED}/sail-e2e-state.json"
: > "${mock_log}"
set +o errexit
env "${base_env[@]}" SHARED_DIR="${TEST_SHARED}" ARTIFACT_DIR="${TEST_ARTIFACTS}" \
  OLM=false bash "${test_script}"
rc=$?
set -o errexit
[ "${rc}" -eq 1 ] || fail "invalid state returned ${rc}"
assert_no_log '^make '

write_state "${TEST_SHARED}/sail-e2e-state.json" true amd64
: > "${mock_log}"
set +o errexit
env "${base_env[@]}" SHARED_DIR="${TEST_SHARED}" ARTIFACT_DIR="${TEST_ARTIFACTS}" \
  OLM=false bash "${test_script}"
rc=$?
set -o errexit
[ "${rc}" -eq 1 ] || fail "OLM mismatch returned ${rc}"
assert_no_log '^make '

write_state "${TEST_SHARED}/sail-e2e-state.json" false ppc64le
: > "${mock_log}"
set +o errexit
env "${base_env[@]}" SHARED_DIR="${TEST_SHARED}" ARTIFACT_DIR="${TEST_ARTIFACTS}" \
  OLM=false bash "${test_script}"
rc=$?
set -o errexit
[ "${rc}" -eq 1 ] || fail "unsupported architecture returned ${rc}"
assert_no_log '^make '

write_state "${TEST_SHARED}/sail-e2e-state.json"
rm -f "${TEST_SHARED}/kubeconfig"
: > "${mock_log}"
set +o errexit
env "${base_env[@]}" SHARED_DIR="${TEST_SHARED}" ARTIFACT_DIR="${TEST_ARTIFACTS}" \
  OLM=false bash "${test_script}"
rc=$?
set -o errexit
[ "${rc}" -eq 1 ] || fail "missing kubeconfig returned ${rc}"
assert_no_log '^make '

# Unset required paths fail with explicit preflight errors instead of nounset.
set +o errexit
env "${base_env[@]}" ARTIFACT_DIR="${tmp}/artifacts" bash "${test_script}" >/dev/null 2>&1
rc=$?
set -o errexit
[ "${rc}" -eq 1 ] || fail "unset SHARED_DIR returned ${rc}"

secrets="${tmp}/secrets"
mkdir -p "${secrets}"
printf 'ci-user\n' > "${secrets}/username"
printf 'ci-password\n' > "${secrets}/password"

run_prepare() {
  local name=$1
  local expected_rc=$2
  shift 2
  local shared="${tmp}/prepare-${name}-shared"
  mkdir -p "${shared}"
  rm -f "${remote_state}" "${password_capture}"
  : > "${mock_log}"
  set +o errexit
  env "${base_env[@]}" SHARED_DIR="${shared}" \
    MAISTRA_NAMESPACE=builder-ns MAISTRA_SC_POD=builder-pod \
    "$@" bash "${prepare_script}"
  local rc=$?
  set -o errexit
  if [ "${rc}" -ne "${expected_rc}" ]; then
    fail "prepare step ${name}: expected rc ${expected_rc}, got ${rc}"
  fi
  PREPARE_SHARED=${shared}
}

base_env+=(QUAY_CREDENTIALS_DIR="${secrets}")

run_prepare helm 0 OLM=false OCP_ARCH=amd64
jq -e '.olm == "false" and .deploymentName == "sail-operator" and .targetArch == "amd64"' \
  "${PREPARE_SHARED}/sail-e2e-state.json" >/dev/null
[ "$(cat "${password_capture}")" = ci-password ] || fail "registry password was not streamed on stdin"
assert_log 'docker login .*--password-stdin quay.io'
assert_log 'BUILD_WITH_CONTAINER=0 .*E2E_STATE_FILE=/work/sail-e2e-state.json'
assert_log '^oc cp '
[ "$(stat -c '%a' "${PREPARE_SHARED}/sail-e2e-state.json")" = 644 ] || fail "shared state mode is not 0644"

run_prepare olm-arm64 0 OLM=true OCP_ARCH=arm64
jq -e '.olm == "true" and .deploymentName == "sailoperator-controller-manager" and .targetArch == "arm64"' \
  "${PREPARE_SHARED}/sail-e2e-state.json" >/dev/null

run_prepare inferred-arch 0 OLM=false MOCK_UNAME_ARCH=aarch64
jq -e '.targetArch == "arm64"' "${PREPARE_SHARED}/sail-e2e-state.json" >/dev/null

run_prepare remote-copy-fail 1 OLM=false OCP_ARCH=amd64 MOCK_REMOTE_COPY_FAIL=true
run_prepare remote-chmod-fail 1 OLM=false OCP_ARCH=amd64 MOCK_REMOTE_CHMOD_FAIL=true
run_prepare local-chmod-fail 1 OLM=false OCP_ARCH=amd64 MOCK_LOCAL_CHMOD_FAIL=true
run_prepare invalid-copied-state 1 OLM=false OCP_ARCH=amd64 MOCK_INVALID_REMOTE_STATE=true

set +o errexit
env "${base_env[@]}" SHARED_DIR="${tmp}/unset-prepare" \
  MAISTRA_SC_POD=builder-pod bash "${prepare_script}" >/dev/null 2>&1
rc=$?
set -o errexit
[ "${rc}" -eq 1 ] || fail "unset MAISTRA_NAMESPACE returned ${rc}"

echo "release Sail phase contract tests passed"
