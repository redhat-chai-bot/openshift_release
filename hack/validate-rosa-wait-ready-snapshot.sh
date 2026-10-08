#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
commands_file="${repo_root}/ci-operator/step-registry/rosa/cluster/wait-ready/cluster/rosa-cluster-wait-ready-cluster-commands.sh"
captured_at="2026-01-02T03:04:05Z"

snapshot_filter=$(awk '
    /# BEGIN OCM_STATE_SNAPSHOT_FILTER/ { capture = 1; next }
    /# END OCM_STATE_SNAPSHOT_FILTER/ { capture = 0 }
    capture
' "${commands_file}")

if [[ -z "${snapshot_filter}" ]]; then
    echo "Unable to find the OCM state snapshot filter in ${commands_file}" >&2
    exit 1
fi

cases=0
while IFS= read -r test_case; do
    name=$(jq -r '.name' <<< "${test_case}")
    input=$(jq -c '.input' <<< "${test_case}")
    expected_classification=$(jq -c '.expected_classification' <<< "${test_case}")
    expected_infra_id_set=$(jq -c '.expected_infra_id_set // false' <<< "${test_case}")

    expected=$(jq -cn \
        --arg captured_at "${captured_at}" \
        --argjson description_classification "${expected_classification}" \
        --argjson infra_id_set "${expected_infra_id_set}" \
        '{
            captured_at: $captured_at,
            state: "installing",
            description_classification: $description_classification,
            infra_id_set: $infra_id_set
        }')
    actual=$(jq -c --arg captured_at "${captured_at}" "${snapshot_filter}" <<< "${input}")

    if [[ "${actual}" != "${expected}" ]]; then
        echo "Snapshot redaction case failed: ${name}" >&2
        echo "Expected: ${expected}" >&2
        echo "Actual:   ${actual}" >&2
        exit 1
    fi
    cases=$((cases + 1))
done < <(jq -c '.[]' <<'JSON'
[
  {
    "name": "quoted external ID, token, and ISO role ARN",
    "input": {
      "state": "installing",
      "status": {
        "description": "failed: {\"external_id\":\"external-value\",\"role_arn\":\"arn:aws-iso:iam::123456789012:role/example\",\"token\":\"token-value\"}"
      },
      "infra_id": "infra-private-abc123"
    },
    "expected_classification": null,
    "expected_infra_id_set": true
  },
  {
    "name": "unquoted and multiword external IDs",
    "input": {
      "state": "installing",
      "status": {
        "description": "external-id=external-value external id is multi word identifier"
      }
    },
    "expected_classification": null
  },
  {
    "name": "quoted and unquoted sensitive values",
    "input": {
      "state": "installing",
      "status": {
        "description": "token=token-value secret: 'multi word secret' password=\"password value\""
      }
    },
    "expected_classification": null
  },
  {
    "name": "all AWS ARN partitions and comma in resource name",
    "input": {
      "state": "installing",
      "status": {
        "description": "arn:aws:iam::123456789012:role/a arn:aws-cn:iam::123456789012:role/b arn:aws-us-gov:iam::123456789012:role/c arn:aws-iso:iam::123456789012:role/d arn:aws-iso-b:iam::123456789012:role/e arn:aws-iso-e:iam::123456789012:role/f arn:aws-iso-f:iam::123456789012:role/name,with-comma"
      }
    },
    "expected_classification": null
  },
  {
    "name": "account ID and UUID",
    "input": {
      "state": "installing",
      "status": {
        "description": "account 123456789012 request 123e4567-e89b-12d3-a456-426614174000"
      }
    },
    "expected_classification": null
  },
  {
    "name": "URL",
    "input": {
      "state": "installing",
      "status": {
        "description": "see https://console.example.invalid/clusters/private-cluster?token=token-value"
      }
    },
    "expected_classification": null
  },
  {
    "name": "opaque cluster and infrastructure identifiers",
    "input": {
      "state": "installing",
      "status": {
        "description": "cluster private-cluster-7gk2 uses infra private-cluster-7gk2-x9p4q"
      },
      "infra_id": "private-cluster-7gk2-x9p4q"
    },
    "expected_classification": null,
    "expected_infra_id_set": true
  },
  {
    "name": "unclassified free text",
    "input": {
      "state": "installing",
      "status": {
        "description": "waiting for an internal reconciliation dependency"
      }
    },
    "expected_classification": null
  },
  {
    "name": "allowlisted ClusterImageSetNotFound signal",
    "input": {
      "state": "installing",
      "status": {
        "description": "ClusterImageSetNotFound"
      }
    },
    "expected_classification": "ClusterImageSetNotFound"
  },
  {
    "name": "allowlisted signal with adversarial details",
    "input": {
      "state": "installing",
      "status": {
        "description": "ClusterImageSetNotFound for private-cluster-7gk2: token=token-value arn:aws-iso:iam::123456789012:role/example"
      },
      "infra_id": "private-cluster-7gk2-x9p4q"
    },
    "expected_classification": "ClusterImageSetNotFound",
    "expected_infra_id_set": true
  },
  {
    "name": "classification is token bounded",
    "input": {
      "state": "installing",
      "status": {
        "description": "privateClusterImageSetNotFoundSuffix"
      }
    },
    "expected_classification": null
  },
  {
    "name": "missing description",
    "input": {
      "state": "installing",
      "status": {}
    },
    "expected_classification": null
  },
  {
    "name": "non-string description",
    "input": {
      "state": "installing",
      "status": {
        "description": {
          "token": "token-value"
        }
      }
    },
    "expected_classification": null
  }
]
JSON
)

echo "Validated ${cases} adversarial OCM state snapshot cases"
