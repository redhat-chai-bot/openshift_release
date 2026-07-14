#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# cd to writeable directory
cd /tmp/

git clone https://github.com/stolostron/policy-collection.git

sleep 60

cd policy-collection/deploy/

# If QUAY_OPERATOR_CHANNEL is set, patch the Quay operator subscription to pin the channel
if [[ -n "${QUAY_OPERATOR_CHANNEL:-}" ]]; then
  QUAY_POLICY_FILE="../policygenerator/policy-sets/stable/openshift-plus/input-quay/policy-install-quay.yaml"
  echo "Patching Quay operator subscription to use channel: ${QUAY_OPERATOR_CHANNEL}"
  sed -i "/^    name: quay-operator$/a\\    channel: ${QUAY_OPERATOR_CHANNEL}" "${QUAY_POLICY_FILE}"
  echo "Patched ${QUAY_POLICY_FILE}:"
  grep -A5 'name: quay-operator' "${QUAY_POLICY_FILE}"
fi

echo 'y' | ./deploy.sh -p policygenerator/policy-sets/stable/openshift-plus -n policies -u https://github.com/stolostron/policy-collection.git -a openshift-plus

sleep 120

# wait for policies to be compliant
RETRIES=40
for try in $(seq "${RETRIES}"); do
  results=$(oc get policies -n policies)
  notready=$(echo "$results" | grep -E 'NonCompliant|Pending' || true)
  if [ "$notready" == "" ]; then
    echo "OPP policyset is applied and compliant"
    break
  else
    if [ $try == $RETRIES ]; then
      if [ "$IGNORE_SECONDARY_POLICIES" == "true" ]; then
        CANDIDATES=$(echo "$notready" | grep -v policy-acs | grep -v policy-advanced-managed-cluster-status | grep -v policy-hub-quay-bridge | grep -v policy-quay-status || true)
        if [ -z "$CANDIDATES" ]; then
          echo "Warning: Proceeding with OPP QE tests with some policy failures"
          exit 0
        else
          echo "Error policies failed to become compliant in allotted time, even considering the ignore list."
          exit 1
        fi
      else
        echo "Error policies failed to become compliant in allotted time."
        exit 1
      fi
    fi
    echo "Try ${try}/${RETRIES}: Policies are not compliant. Checking again in 30 seconds"
    sleep 30
  fi
done
