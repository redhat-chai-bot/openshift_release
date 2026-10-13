#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/ci-operator/step-registry/rosa/e2e/capa/rosa-e2e-capa-commands.sh"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
sed -n '/^echo "Running rosa-hcp-e2e tests/,$p' "${SCRIPT}" > "${WORK_DIR}/run.sh"
test -s "${WORK_DIR}/run.sh"

run_case() {
  local name=$1 runner_status=$2 reports=$3 tee_status=$4 copy_status=$5 rename_status=$6 expected_status=$7
  local case_dir="${WORK_DIR}/${name} with spaces" actual_status=0
  mkdir -p "${case_dir}/checkout" "${case_dir}/artifacts"
  set +e
  (
    set -euo pipefail
    cd "${case_dir}/checkout"
    export ARTIFACT_DIR="${case_dir}/artifacts"
    export NAME_PREFIX=ciunit TEST_SUITE='--tag standalone' PYTHON=mock_runner
    EXTRA_VARS=(-e 'value=with spaces')
    printf '%s\n' run-test-suite.py --tag standalone --ai-agent "${EXTRA_VARS[@]}" > "${case_dir}/expected-args"
    mock_runner() {
      printf '%s\n' "$@" > runner-args
      echo 'mock test output'
      echo 'mock test stderr' >&2
      if [[ ${reports} != missing ]]; then
        mkdir -p 'test-results/2026-10-13' 'test-results/2026-10-14'
        printf '{"passed":1}\n' > 'test-results/2026-10-13/test-run suite.json'
        printf '<html>report</html>\n' > 'test-results/2026-10-13/test-run suite.html'
        if [[ ${reports} != no-junit ]]; then
          printf '<testsuite/>\n' > 'test-results/2026-10-13/test-run suite.xml'
          printf '<testsuite/>\n' > 'test-results/2026-10-14/test-run suite.xml'
          printf '<testsuite/>\n' > test-results/latest.xml
        fi
      fi
      return "${runner_status}"
    }
    tee() {
      if [[ ${name} == tee-open-failure ]]; then
        command tee "${ARTIFACT_DIR}"
        return $?
      fi
      command tee "$@"
      return "${tee_status}"
    }
    cp() {
      if [[ ${copy_status} -ne 0 ]]; then
        echo 'mock copy failure' >&2
        return "${copy_status}"
      fi
      command cp "$@"
    }
    mv() {
      if [[ ${rename_status} -ne 0 ]]; then
        echo 'mock rename failure' >&2
        return "${rename_status}"
      fi
      command mv "$@"
    }
    source "${WORK_DIR}/run.sh"
  ) > "${case_dir}/output" 2>&1
  actual_status=$?
  set -e
  if [[ ${actual_status} -ne ${expected_status} ]]; then
    cat "${case_dir}/output"
    echo "FAIL: ${name}: expected ${expected_status}, got ${actual_status}" >&2
    exit 1
  fi
  if [[ ${name} != tee-open-failure ]]; then
    printf '%s\n' 'mock test output' 'mock test stderr' > "${case_dir}/expected-log"
    cmp "${case_dir}/expected-log" "${case_dir}/artifacts/rosa-hcp-e2e-test.log"
  fi
  cmp "${case_dir}/expected-args" "${case_dir}/checkout/runner-args"
  if [[ ${reports} == missing ]]; then
    grep -q 'WARNING: test-results directory is missing' "${case_dir}/output"
  elif [[ ${copy_status} -eq 0 ]]; then
    cmp "${case_dir}/checkout/test-results/2026-10-13/test-run suite.json" "${case_dir}/artifacts/test-results/2026-10-13/test-run suite.json"
    cmp "${case_dir}/checkout/test-results/2026-10-13/test-run suite.html" "${case_dir}/artifacts/test-results/2026-10-13/test-run suite.html"
    if [[ ${reports} == no-junit ]]; then
      grep -q 'WARNING: no dated JUnit reports found' "${case_dir}/output"
    elif [[ ${rename_status} -eq 0 ]]; then
      for date in 2026-10-13 2026-10-14; do
        cmp "${case_dir}/checkout/test-results/${date}/test-run suite.xml" "${case_dir}/artifacts/test-results/${date}/junit_test-run suite.xml"
        test ! -e "${case_dir}/artifacts/test-results/${date}/test-run suite.xml"
      done
      test -f "${case_dir}/artifacts/test-results/latest.xml"
    fi
  fi
  if [[ ${tee_status} -ne 0 ]]; then
    grep -q "ERROR: tee failed with exit code ${tee_status}" "${case_dir}/output"
  fi
  if [[ ${copy_status} -ne 0 ]]; then
    grep -q 'ERROR: could not copy test-results' "${case_dir}/output"
  fi
  if [[ ${rename_status} -ne 0 ]]; then
    grep -q 'ERROR: could not rename JUnit report' "${case_dir}/output"
  fi
  if [[ ${runner_status} -ne 0 ]]; then
    grep -q "ERROR: test runner failed with exit code ${runner_status}" "${case_dir}/output"
  fi
  echo "PASS: ${name} (exit ${actual_status})"
}

run_case success 0 present 0 0 0 0
run_case failed-runner 23 present 0 0 0 23
run_case missing-reports 0 missing 0 0 0 0
run_case failed-runner-missing-reports 23 missing 0 0 0 23
run_case missing-junit 0 no-junit 0 0 0 0
run_case tee-failure 0 present 17 0 0 17
run_case tee-open-failure 0 present 1 0 0 1
run_case copy-failure 0 present 0 19 0 19
run_case rename-failure 0 present 0 0 21 21
run_case runner-and-tee-failure 23 present 17 0 0 23
run_case runner-and-copy-failure 23 present 0 19 0 23
run_case runner-and-rename-failure 23 present 0 0 21 23
run_case all-failures 23 present 17 19 0 23
