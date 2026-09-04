#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
UNIVERSE_DOMAIN=$(jq -r ".universe_domain // empty" "${GOOGLE_CLOUD_KEYFILE_JSON}" 2>/dev/null)
if [[ -n "${UNIVERSE_DOMAIN}" ]]; then
  export GOOGLE_CLOUD_UNIVERSE_DOMAIN="${UNIVERSE_DOMAIN}"
  gcloud config set universe_domain "${UNIVERSE_DOMAIN}"
fi
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"

if test ! -f "${SHARED_DIR}/metadata.json"
then
	echo "No metadata.json, so unknown GCP project and infra ID, so unable to gather load balancer data."
	exit 0
fi

PROJECT_ID="$(jq -r '.gcp.projectID' "${SHARED_DIR}/metadata.json")"
INFRA_ID="$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")"
REGION="$(jq -r '.gcp.region' "${SHARED_DIR}/metadata.json")"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
	echo "Could not determine GCP project ID from metadata.json."
	exit 0
fi

if [[ -z "${INFRA_ID}" || "${INFRA_ID}" == "null" ]]; then
	echo "Could not determine infrastructure ID from metadata.json."
	exit 0
fi

if [[ -z "${REGION}" || "${REGION}" == "null" ]]; then
	echo "Could not determine GCP region from metadata.json."
	exit 0
fi

gcloud config set project "${PROJECT_ID}"

# while gathering data from a private cluster, proxy setting is required for connecting cluster
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	echo "Going to enable client proxy by 'source ${SHARED_DIR}/proxy-conf.sh'"
	source "${SHARED_DIR}/proxy-conf.sh"
else
	echo "No '${SHARED_DIR}/proxy-conf.sh' found, skip enabling client proxy."
fi

OUTPUT_DIR="${ARTIFACT_DIR}/gcp-load-balancer"
mkdir -p "${OUTPUT_DIR}"

echo "Gathering GCP load balancer resources for infra ID '${INFRA_ID}' in project '${PROJECT_ID}', region '${REGION}'..."

# From here on, do not exit on individual command failures so we can
# collect as much data as possible.
set +o errexit

#
# Forwarding rules (regional)
#
echo "Collecting forwarding rules..."
FORWARDING_RULES=$(gcloud compute forwarding-rules list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --format=json 2>/dev/null)

echo "${FORWARDING_RULES}" > "${OUTPUT_DIR}/forwarding-rules-list.json"

if [[ -n "${FORWARDING_RULES}" && "${FORWARDING_RULES}" != "[]" ]]; then
  for rule_name in $(echo "${FORWARDING_RULES}" | jq -r '.[].name'); do
    # Determine if the rule is regional or global from its selfLink
    rule_region=$(echo "${FORWARDING_RULES}" | jq -r ".[] | select(.name==\"${rule_name}\") | .region // empty")
    if [[ -n "${rule_region}" ]]; then
      gcloud compute forwarding-rules describe "${rule_name}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --format=json > "${OUTPUT_DIR}/forwarding-rule-${rule_name}.json" 2>/dev/null
    else
      gcloud compute forwarding-rules describe "${rule_name}" \
        --project="${PROJECT_ID}" \
        --global \
        --format=json > "${OUTPUT_DIR}/forwarding-rule-${rule_name}.json" 2>/dev/null
    fi
  done
fi

#
# Target pools (regional)
#
echo "Collecting target pools..."
TARGET_POOLS=$(gcloud compute target-pools list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --regions="${REGION}" \
  --format=json 2>/dev/null)

echo "${TARGET_POOLS}" > "${OUTPUT_DIR}/target-pools-list.json"

if [[ -n "${TARGET_POOLS}" && "${TARGET_POOLS}" != "[]" ]]; then
  for pool_name in $(echo "${TARGET_POOLS}" | jq -r '.[].name'); do
    gcloud compute target-pools describe "${pool_name}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --format=json > "${OUTPUT_DIR}/target-pool-${pool_name}.json" 2>/dev/null

    gcloud compute target-pools get-health "${pool_name}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --format=json > "${OUTPUT_DIR}/target-pool-health-${pool_name}.json" 2>/dev/null
  done
fi

#
# Backend services (regional and global)
#
echo "Collecting backend services..."
BACKEND_SERVICES=$(gcloud compute backend-services list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --format=json 2>/dev/null)

echo "${BACKEND_SERVICES}" > "${OUTPUT_DIR}/backend-services-list.json"

if [[ -n "${BACKEND_SERVICES}" && "${BACKEND_SERVICES}" != "[]" ]]; then
  for bs_name in $(echo "${BACKEND_SERVICES}" | jq -r '.[].name'); do
    bs_region=$(echo "${BACKEND_SERVICES}" | jq -r ".[] | select(.name==\"${bs_name}\") | .region // empty")
    if [[ -n "${bs_region}" ]]; then
      gcloud compute backend-services describe "${bs_name}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --format=json > "${OUTPUT_DIR}/backend-service-${bs_name}.json" 2>/dev/null

      gcloud compute backend-services get-health "${bs_name}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --format=json > "${OUTPUT_DIR}/backend-service-health-${bs_name}.json" 2>/dev/null
    else
      gcloud compute backend-services describe "${bs_name}" \
        --project="${PROJECT_ID}" \
        --global \
        --format=json > "${OUTPUT_DIR}/backend-service-${bs_name}.json" 2>/dev/null

      gcloud compute backend-services get-health "${bs_name}" \
        --project="${PROJECT_ID}" \
        --global \
        --format=json > "${OUTPUT_DIR}/backend-service-health-${bs_name}.json" 2>/dev/null
    fi
  done
fi

#
# Health checks (global)
#
echo "Collecting health checks..."
HEALTH_CHECKS=$(gcloud compute health-checks list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --format=json 2>/dev/null)

echo "${HEALTH_CHECKS}" > "${OUTPUT_DIR}/health-checks-list.json"

if [[ -n "${HEALTH_CHECKS}" && "${HEALTH_CHECKS}" != "[]" ]]; then
  for hc_name in $(echo "${HEALTH_CHECKS}" | jq -r '.[].name'); do
    gcloud compute health-checks describe "${hc_name}" \
      --project="${PROJECT_ID}" \
      --format=json > "${OUTPUT_DIR}/health-check-${hc_name}.json" 2>/dev/null
  done
fi

#
# Firewall rules
#
echo "Collecting firewall rules..."
gcloud compute firewall-rules list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --format=json > "${OUTPUT_DIR}/firewall-rules-list.json" 2>/dev/null

#
# Target TCP/SSL/HTTPS proxies (global, if any)
#
echo "Collecting target TCP proxies..."
gcloud compute target-tcp-proxies list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --format=json > "${OUTPUT_DIR}/target-tcp-proxies-list.json" 2>/dev/null

#
# Cloud Logging: load-balancer-related log entries (best effort, limited)
#
echo "Collecting load balancer log entries from Cloud Logging..."
gcloud logging read \
  "resource.type=\"gce_forwarding_rule\" OR resource.type=\"http_load_balancer\" OR resource.type=\"tcp_ssl_proxy_rule\" OR resource.type=\"network_tcp_ssl_proxy_rule\"" \
  --project="${PROJECT_ID}" \
  --limit=200 \
  --freshness=3h \
  --format=json > "${OUTPUT_DIR}/lb-log-entries.json" 2>/dev/null

echo "GCP load balancer resource gathering complete. Output written to ${OUTPUT_DIR}/"
