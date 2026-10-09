#!/bin/bash

set -o nounset
set -o pipefail

name=$(basename "$0")
{
  printf '%s' "${name}"
  printf ' %q' "$@"
  printf '\n'
} >> "${MOCK_LOG}"

case "${name}" in
  make)
    if [ "${MOCK_CREATE_REPORT:-false}" = true ]; then
      mkdir -p "${ARTIFACT_DIR}"
      printf '<testsuite/>\n' > "${ARTIFACT_DIR}/report.xml"
    fi
    exit "${MOCK_SUITE_RC:-0}"
    ;;
  cp)
    if [ "${MOCK_REPORT_COPY_FAIL:-false}" = true ] &&
      [ "${1:-}" = "${ARTIFACT_DIR:-}/report.xml" ]; then
      exit 31
    fi
    /bin/cp "$@"
    ;;
  chmod)
    if [ "${MOCK_LOCAL_CHMOD_FAIL:-false}" = true ] &&
      [ "${2:-}" = "${SHARED_DIR:-}/sail-e2e-state.json" ]; then
      exit 32
    fi
    /bin/chmod "$@"
    ;;
  oc)
    all_args=$*
    if [[ " ${all_args} " == *" docker login "* ]]; then
      IFS= read -r password || true
      printf '%s' "${password}" > "${MOCK_PASSWORD_CAPTURE}"
      exit 0
    fi
    if [[ " ${all_args} " == *" entrypoint make test.e2e.ocp.prepare"* ]]; then
      olm=false
      arch=amd64
      for arg in "$@"; do
        case "${arg}" in
          OLM=*) olm=${arg#OLM=} ;;
          TARGET_ARCH=*) arch=${arg#TARGET_ARCH=} ;;
        esac
      done
      if [ "${MOCK_INVALID_REMOTE_STATE:-false}" = true ]; then
        printf '{"schemaVersion":99}\n' > "${MOCK_REMOTE_STATE}"
      else
        deployment=sail-operator
        if [ "${olm}" = true ]; then
          deployment=sailoperator-controller-manager
        fi
        printf '{"schemaVersion":1,"hub":"quay.io/sail-dev","tag":"exact-tag","imageBase":"sail-operator","namespace":"sail-operator","olm":"%s","deploymentName":"%s","targetArch":"%s"}\n' \
          "${olm}" "${deployment}" "${arch}" > "${MOCK_REMOTE_STATE}"
      fi
      exit "${MOCK_PREPARE_RC:-0}"
    fi
    if [[ " ${all_args} " == *" chmod 0644 /work/sail-e2e-state.json"* ]]; then
      if [ "${MOCK_REMOTE_CHMOD_FAIL:-false}" = true ]; then
        exit 33
      fi
      exit 0
    fi
    if [ "${1:-}" = cp ]; then
      if [ "${MOCK_REMOTE_COPY_FAIL:-false}" = true ]; then
        exit 34
      fi
      /bin/cp "${MOCK_REMOTE_STATE}" "${@: -1}"
      exit 0
    fi
    if [[ " ${all_args} " == *" uname -m"* ]]; then
      printf '%s\n' "${MOCK_UNAME_ARCH:-x86_64}"
      exit 0
    fi
    exit 0
    ;;
esac
