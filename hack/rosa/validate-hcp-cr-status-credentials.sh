#!/bin/bash
set +x
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${HCP_CR_STATUS_SCRIPT:-${REPO_ROOT}/ci-operator/step-registry/rosa/gather/hcp-cr-status/rosa-gather-hcp-cr-status-commands.sh}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
mkdir -p "${WORK_DIR}/bin" "${WORK_DIR}/tmp" "${WORK_DIR}/home" "${WORK_DIR}/shared" "${WORK_DIR}/credentials"
printf 'offline-cluster\n' > "${WORK_DIR}/shared/cluster-id"
sed -e "s|/tmp/|${WORK_DIR}/tmp/|g" \
    -e "s|/usr/local/cs-qe-credentials|${WORK_DIR}/credentials|g" "${SCRIPT}" > "${WORK_DIR}/commands.sh"

cat > "${WORK_DIR}/bin/ocm" <<'STUB'
#!/bin/bash
set +x
printf '%s\0' "$@" > "${TEST_DIR}/ocm-args"
exit "${LOGIN_STATUS}"
STUB
cat > "${WORK_DIR}/bin/ocm-backplane" <<'STUB'
#!/bin/bash
set +x
printf '%s\0' "$@" > "${TEST_DIR}/backplane-args"
exit 1
STUB
cat > "${WORK_DIR}/bin/tar" <<'STUB'
#!/bin/bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-C" ]]; then
    cp "${TEST_DIR}/bin/ocm-backplane" "$2/ocm-backplane"
    exit 0
  fi
  shift
done
exit 1
STUB
cat > "${WORK_DIR}/bin/curl" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "${WORK_DIR}/bin/oc" <<'STUB'
#!/bin/bash
touch "${TEST_DIR}/unexpected-cluster-call"
exit 1
STUB
chmod +x "${WORK_DIR}/bin/"*

printf '%s\n' dummy-sso-id dummy-sso-secret dummy-backplane-id dummy-backplane-secret \
  dummy-token dummy-underscore-token dummy-hyphen-token dummy-role-token > "${WORK_DIR}/secret-patterns"
PASS=0
FAIL=0

reset_credentials() {
  rm -f "${WORK_DIR}/credentials/"*
}

sso_pair() {
  printf 'dummy-sso-id\n' > "${WORK_DIR}/credentials/sso-client-id"
  printf 'dummy-sso-secret\n' > "${WORK_DIR}/credentials/sso-client-secret"
}

backplane_pair() {
  printf 'dummy-backplane-id\n' > "${WORK_DIR}/credentials/backplane_client_id"
  printf 'dummy-backplane-secret\n' > "${WORK_DIR}/credentials/backplane_client_secret"
}

run_case() {
  local label="$1" format="$2"
  shift 2
  local tracing status failed
  for tracing in off on; do
    rm -f "${WORK_DIR}/ocm-args" "${WORK_DIR}/backplane-args" "${WORK_DIR}/unexpected-cluster-call"
    local bash_args=()
    [[ "${tracing}" == on ]] && bash_args+=(-x)
    status=0
    env -i HOME="${WORK_DIR}/home" PATH="${WORK_DIR}/bin:/usr/bin:/bin" \
      ARTIFACT_DIR="${WORK_DIR}/artifacts" SHARED_DIR="${WORK_DIR}/shared" \
      OCM_LOGIN_ENV=integration TEST_DIR="${WORK_DIR}" LOGIN_STATUS="${LOGIN_STATUS:-0}" \
      bash "${bash_args[@]}" "${WORK_DIR}/commands.sh" \
      > "${WORK_DIR}/stdout" 2> "${WORK_DIR}/stderr" || status=$?
    failed=false
    [[ "${status}" == 0 ]] || failed=true
    if [[ "${format}" == none ]]; then
      [[ ! -f "${WORK_DIR}/ocm-args" && ! -f "${WORK_DIR}/backplane-args" ]] || failed=true
      grep -Fq 'ERROR: No OCM credentials found' "${WORK_DIR}/stdout" || failed=true
    else
      printf '%s\0' login --url integration "$@" > "${WORK_DIR}/expected-args"
      cmp -s "${WORK_DIR}/expected-args" "${WORK_DIR}/ocm-args" || failed=true
      if [[ "${LOGIN_STATUS:-0}" == 0 ]]; then
        printf '%s\0' login offline-cluster > "${WORK_DIR}/expected-backplane-args"
        cmp -s "${WORK_DIR}/expected-backplane-args" "${WORK_DIR}/backplane-args" || failed=true
      else
        [[ ! -f "${WORK_DIR}/backplane-args" ]] || failed=true
        grep -Fq 'ERROR: OCM login with' "${WORK_DIR}/stdout" || failed=true
      fi
    fi
    [[ ! -f "${WORK_DIR}/unexpected-cluster-call" ]] || failed=true
    if grep -Fq -f "${WORK_DIR}/secret-patterns" "${WORK_DIR}/stdout" "${WORK_DIR}/stderr"; then
      failed=true
    fi
    if "${failed}"; then
      echo "FAIL: ${label} (tracing ${tracing})"
      FAIL=$((FAIL + 1))
    else
      echo "PASS: ${label} (tracing ${tracing}, exit 0, no secret output)"
      PASS=$((PASS + 1))
    fi
  done
}

reset_credentials
backplane_pair
run_case backplane-pair client --client-id dummy-backplane-id --client-secret dummy-backplane-secret
LOGIN_STATUS=1 run_case failed-client-login client --client-id dummy-backplane-id --client-secret dummy-backplane-secret
sso_pair
run_case sso-precedence client --client-id dummy-sso-id --client-secret dummy-sso-secret
LOGIN_STATUS=1 run_case failed-sso-no-retry client --client-id dummy-sso-id --client-secret dummy-sso-secret
reset_credentials
sso_pair
run_case legacy-sso client --client-id dummy-sso-id --client-secret dummy-sso-secret

for token_file in ocm-tokens ocm_token ocm-token; do
  reset_credentials
  if [[ "${token_file}" == ocm-tokens ]]; then
    printf 'OCM_TOKEN=dummy-token\nSREP_TOKEN=dummy-role-token\n' > "${WORK_DIR}/credentials/${token_file}"
  else
    printf 'dummy-token\n' > "${WORK_DIR}/credentials/${token_file}"
  fi
  run_case "legacy-${token_file}" token --token dummy-token
  LOGIN_STATUS=1 run_case "failed-${token_file}-login" token --token dummy-token
  backplane_pair
  run_case "client-before-${token_file}" client --client-id dummy-backplane-id --client-secret dummy-backplane-secret
done

reset_credentials
printf 'OCM_TOKEN=dummy-token\n' > "${WORK_DIR}/credentials/ocm-tokens"
printf 'dummy-underscore-token\n' > "${WORK_DIR}/credentials/ocm_token"
printf 'dummy-hyphen-token\n' > "${WORK_DIR}/credentials/ocm-token"
run_case token-precedence token --token dummy-token
rm "${WORK_DIR}/credentials/ocm-tokens"
run_case underscore-token-precedence token --token dummy-underscore-token
reset_credentials
printf 'SREP_TOKEN=dummy-role-token\n' > "${WORK_DIR}/credentials/ocm-tokens"
run_case no-arbitrary-role-token none
reset_credentials
run_case missing-credentials none

for prefix in sso backplane; do
  if [[ "${prefix}" == sso ]]; then
    id_file=sso-client-id
    secret_file=sso-client-secret
  else
    id_file=backplane_client_id
    secret_file=backplane_client_secret
  fi
  for invalid in missing-id missing-secret empty-id empty-secret empty-pair; do
    reset_credentials
    "${prefix}_pair"
    case "${invalid}" in
      missing-id) rm "${WORK_DIR}/credentials/${id_file}" ;;
      missing-secret) rm "${WORK_DIR}/credentials/${secret_file}" ;;
      empty-id) : > "${WORK_DIR}/credentials/${id_file}" ;;
      empty-secret) : > "${WORK_DIR}/credentials/${secret_file}" ;;
      empty-pair) : > "${WORK_DIR}/credentials/${id_file}"; : > "${WORK_DIR}/credentials/${secret_file}" ;;
    esac
    run_case "${prefix}-${invalid}" none
    printf 'dummy-token\n' > "${WORK_DIR}/credentials/ocm-token"
    run_case "${prefix}-${invalid}-token-fallback" token --token dummy-token
    if [[ "${prefix}" == sso ]]; then
      backplane_pair
      run_case "${prefix}-${invalid}-client-fallback" client --client-id dummy-backplane-id --client-secret dummy-backplane-secret
    fi
  done
done

reset_credentials
printf 'dummy-sso-id\n' > "${WORK_DIR}/credentials/sso-client-id"
printf 'dummy-backplane-secret\n' > "${WORK_DIR}/credentials/backplane_client_secret"
run_case no-mixed-pair none

echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" == 0 ]]
