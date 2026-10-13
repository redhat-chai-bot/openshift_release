#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/ci-operator/step-registry/rosa/e2e/capa/rosa-e2e-capa-commands.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "${TEST_DIR}"' EXIT
mkdir -p "${TEST_DIR}/bin"

cat > "${TEST_DIR}/bin/mktemp" <<'EOF'
#!/bin/bash
mkdir -p "${CASE_DIR}/work"
echo "${CASE_DIR}/work"
EOF
cat > "${TEST_DIR}/bin/mkdir" <<'EOF'
#!/bin/bash
if [[ "${@: -1}" == "${ARTIFACT_DIR}/test-results/"* && "${MKDIR_STATUS}" -ne 0 ]]; then
  echo 'fixture artifact mkdir failure' >&2
  exit "${MKDIR_STATUS}"
fi
exec /bin/mkdir "$@"
EOF
cat > "${TEST_DIR}/bin/cat" <<'EOF'
#!/bin/bash
case "$1" in
  /var/run/rosa-hcp-e2e-secrets/*|/var/run/rosa-e2e-aws-creds/*) echo placeholder ;;
  *) exec /bin/cat "$@" ;;
esac
EOF
cat > "${TEST_DIR}/bin/grep" <<'EOF'
#!/bin/bash
if [[ "${2:-}" == /var/run/rosa-e2e-aws-creds/awsEncodedCredentials ]]; then
  echo "$1 = placeholder"
else
  exec /bin/grep "$@"
fi
EOF
cat > "${TEST_DIR}/bin/git" <<'EOF'
#!/bin/bash
if [[ "${SETUP_STATUS}" -ne 0 ]]; then
  exit "${SETUP_STATUS}"
fi
mkdir -p "${@: -1}"
if [[ "${DEPENDENCY_STATUS}" -ne 0 ]]; then
  touch "${@: -1}/requirements.txt"
fi
EOF
cat > "${TEST_DIR}/bin/python3" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == -m ]]; then
  exit "${DEPENDENCY_STATUS}"
fi
if [[ "${CREATE_REPORTS}" == true ]]; then
  for day in 2026-10-12 2026-10-13; do
    mkdir -p "test-results/${day}"
    for extension in json html xml; do
      printf 'report-%s-%s\n' "${day}" "${extension}" > "test-results/${day}/test-run-suite-20261013_120000.${extension}"
      cp "test-results/${day}/test-run-suite-20261013_120000.${extension}" "test-results/latest-suite.${extension}"
    done
  done
fi
echo 'runner output'
exit "${RUNNER_STATUS}"
EOF
cat > "${TEST_DIR}/bin/cp" <<'EOF'
#!/bin/bash
if [[ "$2" == "${ARTIFACT_DIR}"/* && "${COPY_STATUS}" -ne 0 ]]; then
  exit "${COPY_STATUS}"
fi
exec /bin/cp "$@"
EOF
cat > "${TEST_DIR}/bin/tee" <<'EOF'
#!/bin/bash
/usr/bin/tee "$@"
exit "${TEE_STATUS}"
EOF
cat > "${TEST_DIR}/bin/jq" <<'EOF'
#!/bin/bash
echo jq-mock
EOF
cat > "${TEST_DIR}/bin/helm" <<'EOF'
#!/bin/bash
echo helm-mock
EOF
chmod +x "${TEST_DIR}/bin/"*

run_case() {
  local name=$1 expected=$2 runner_status=$3 create_reports=$4 copy_status=$5 tee_status=$6 setup_status=$7
  local mkdir_status=${8:-0} dependency_status=${9:-0}
  local case_dir="${TEST_DIR}/${name}" actual=0 xml_count report_count
  mkdir -p "${case_dir}/artifacts"
  env PATH="${TEST_DIR}/bin:${PATH}" \
    SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" \
    ROSA_HCP_E2E_REPO=https://example.invalid/test ROSA_HCP_E2E_BRANCH=main \
    DEPLOYMENT_MODE=standalone OPENSHIFT_VERSION='' CHANNEL_GROUP='' TEST_SUITE=fixture \
    RUNNER_STATUS="${runner_status}" CREATE_REPORTS="${create_reports}" \
    COPY_STATUS="${copy_status}" TEE_STATUS="${tee_status}" SETUP_STATUS="${setup_status}" \
    CASE_DIR="${case_dir}" MKDIR_STATUS="${mkdir_status}" DEPENDENCY_STATUS="${dependency_status}" \
    bash "${SCRIPT}" > "${case_dir}/output" 2>&1 || actual=$?
  if [[ "${actual}" -ne "${expected}" ]]; then
    echo "FAIL: ${name}: expected ${expected}, got ${actual}"
    cat "${case_dir}/output"
    exit 1
  fi
  xml_count=$(find "${case_dir}/artifacts" -name '*.xml' | wc -l)
  report_count=$(find "${case_dir}/artifacts" -type f \( -name '*.json' -o -name '*.html' \) | wc -l)
  if [[ "${create_reports}" == true && "${copy_status}" -eq 0 && "${setup_status}" -eq 0 && "${mkdir_status}" -eq 0 && "${dependency_status}" -eq 0 ]]; then
    [[ "${xml_count}" -eq 2 && "${report_count}" -eq 4 ]]
    for day in 2026-10-12 2026-10-13; do
      for extension in json html xml; do
        local prefix=''
        [[ "${extension}" != xml ]] || prefix=junit-
        [[ "$(cat "${case_dir}/artifacts/test-results/${day}/${prefix}test-run-suite-20261013_120000.${extension}")" == "report-${day}-${extension}" ]]
      done
    done
    [[ -z "$(find "${case_dir}/artifacts" -name 'latest*')" ]]
  else
    [[ "${xml_count}" -eq 0 && "${report_count}" -eq 0 ]]
  fi
  if [[ "${setup_status}" -eq 0 && "${dependency_status}" -eq 0 ]]; then
    [[ "$(cat "${case_dir}/artifacts/rosa-hcp-e2e-test.log")" == 'runner output' ]]
  fi
  if [[ "${create_reports}" == false || "${dependency_status}" -ne 0 ]]; then
    grep -q 'No runner test-results directory to collect.' "${case_dir}/output"
  fi
  if [[ "${copy_status}" -ne 0 ]]; then
    grep -q 'ERROR: failed to collect runner report' "${case_dir}/output"
  fi
  echo "PASS: ${name} (exit ${actual}; XML ${xml_count}; JSON/HTML ${report_count})"
}

run_case success 0 0 true 0 0 0
run_case test_failure 7 7 true 0 0 0
run_case missing_results_success 0 0 false 0 0 0
run_case missing_results_failure 7 7 false 0 0 0
run_case copy_failure 1 0 true 9 0 0
run_case test_and_copy_failure 7 7 true 9 0 0
run_case tee_failure 8 0 true 0 8 0
run_case test_and_tee_failure 8 7 true 0 8 0
run_case setup_failure 41 0 false 0 0 41
run_case mkdir_failure 1 0 true 0 0 0 9
run_case test_and_mkdir_failure 7 7 true 0 0 0 9
run_case dependency_failure 43 0 false 0 0 0 0 43
run_case tee_and_copy_failure 8 0 true 9 8 0

echo 'PASS: all 13 CAPA artifact regression cases'
