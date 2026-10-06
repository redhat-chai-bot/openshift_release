#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
INSTALL_SCRIPT="${REPO_ROOT}/ci-operator/step-registry/rosa/operator/install/rosa-operator-install-commands.sh"
CLEANUP_SCRIPT="${REPO_ROOT}/ci-operator/step-registry/rosa/operator/cleanup/rosa-operator-cleanup-commands.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_jq() {
    local file="$1"
    local expression="$2"

    jq -e "${expression}" "${file}" >/dev/null || fail "jq assertion failed: ${expression}"
}

test_required_cr_parsing_and_sanitization() (
    export ROSA_OPERATOR_INSTALL_TEST_MODE=true
    # shellcheck source=/dev/null
    source "${INSTALL_SCRIPT}"

    parse_required_cr_entry "subjectpermissions.managed.openshift.io/dedicated-admins/openshift-config" \
        || fail "namespaced required CR entry was rejected"
    [[ "${REQUIRED_RESOURCE_TYPE}" == "subjectpermissions.managed.openshift.io" ]]
    [[ "${REQUIRED_CR_NAME}" == "dedicated-admins" ]]
    [[ "${REQUIRED_CR_NAMESPACE}" == "openshift-config" ]]
    if parse_required_cr_entry "missing-resource-name"; then
        fail "invalid required CR entry was accepted"
    fi

    local workdir
    local backup
    workdir=$(mktemp -d)
    trap 'rm -rf "${workdir}"' EXIT
    chmod 0700 "${workdir}"
    backup="${workdir}/0.json"
    jq -n '{
        apiVersion: "managed.openshift.io/v1alpha1",
        kind: "SubjectPermission",
        metadata: {
            name: "dedicated-admins",
            namespace: "openshift-config",
            uid: "server-uid",
            resourceVersion: "42",
            ownerReferences: [
                {apiVersion: "package-operator.run/v1alpha1", kind: "ClusterObjectSet", name: "stale", uid: "stale-uid"},
                {apiVersion: "apps/v1", kind: "Deployment", name: "valid-owner", uid: "valid-uid"}
            ],
            annotations: {"kubectl.kubernetes.io/last-applied-configuration": "sensitive"}
        },
        spec: {permissions: ["admin"]},
        status: {state: "Ready"}
    }' | write_required_cr_backup "${backup}"

    [[ "$(stat -c '%a' "${workdir}")" == "700" ]] || fail "backup directory mode is not 0700"
    [[ "$(stat -c '%a' "${backup}")" == "600" ]] || fail "backup file mode is not 0600"
    assert_jq "${backup}" '(.metadata.ownerReferences | length) == 1'
    assert_jq "${backup}" '.metadata.ownerReferences[0].name == "valid-owner"'
    assert_jq "${backup}" 'has("status") | not'
    assert_jq "${backup}" '.metadata | has("uid") | not'
    assert_jq "${backup}" '.spec.permissions == ["admin"]'

    mkdir "${workdir}/bin"
    printf '#!/bin/bash\nexit 0\n' > "${workdir}/bin/oc"
    chmod +x "${workdir}/bin/oc"
    PATH="${workdir}/bin:${PATH}"
    REQUIRED_CR_BACKUP_DIR="${workdir}"
    export PATH REQUIRED_CR_BACKUP_DIR
    restore_required_cr_backups
    [[ -f "${backup}" ]] || fail "install deleted recovery backup before all fatal gates passed"
)

test_crd_diagnostics_exact_allowlist() (
    export ROSA_OPERATOR_INSTALL_TEST_MODE=true
    # shellcheck source=/dev/null
    source "${INSTALL_SCRIPT}"

    local workdir
    local fakebin
    local artifact
    workdir=$(mktemp -d)
    trap 'rm -rf "${workdir}"' EXIT
    fakebin="${workdir}/bin"
    mkdir "${fakebin}" "${workdir}/artifacts"
    artifact="${workdir}/artifacts/crd-ownership-test.jsonl"

    cat > "${fakebin}/oc" <<'EOF'
#!/bin/bash
if [[ "$2" == "clusterpackage" ]]; then
    jq -n '{
        metadata: {name: "widget-operator", labels: {"package-operator.run/instance": "widget-operator"}},
        spec: {paused: false, config: {password: "CLUSTERPACKAGE-SECRET"}},
        status: {phase: "Progressing", conditions: [{type: "Available", status: "False", reason: "Deploying", message: "MESSAGE-SECRET"}]}
    }'
    exit 0
fi
jq -n '{
    metadata: {
        name: "widgets.example.com",
        labels: {
            "package-operator.run/instance": "widget-operator",
            "package-operator.run/payload": "LABEL-SECRET",
            "hive.openshift.io/managed": "true",
            "hive.openshift.io/config": "HIVE-SECRET"
        },
        annotations: {
            "package-operator.run/revision": "7",
            "package-operator.run/package-config": "CONFIG-SECRET",
            "package-operator.run/resource": "RESOURCE-SECRET"
        },
        ownerReferences: [{apiVersion: "v1", kind: "ConfigMap", name: "owner", uid: "owner-uid"}]
    }
}'
EOF
    chmod +x "${fakebin}/oc"
    PATH="${fakebin}:${PATH}"
    export PATH
    ARTIFACT_DIR="${workdir}/artifacts"
    OPERATOR_CRDS="widgets.example.com"
    export ARTIFACT_DIR OPERATOR_CRDS

    collect_crd_ownership test
    assert_jq "${artifact}" '.labels == {"hive.openshift.io/managed":"true","package-operator.run/instance":"widget-operator"}'
    assert_jq "${artifact}" '.annotations == {"package-operator.run/revision":"7"}'
    assert_jq "${artifact}" '.ownerReferences[0] == {apiVersion:"v1",kind:"ConfigMap",name:"owner",uid:"owner-uid",controller:null,blockOwnerDeletion:null}'
    if grep -Eq 'CONFIG-SECRET|RESOURCE-SECRET|LABEL-SECRET|HIVE-SECRET|package-config' "${artifact}"; then
        fail "payload-bearing CRD metadata reached the ownership artifact"
    fi

    clusterpackage_diagnostic widget-operator > "${workdir}/artifacts/clusterpackage.json"
    assert_jq "${workdir}/artifacts/clusterpackage.json" '.spec == {paused:false}'
    if grep -Eq 'CLUSTERPACKAGE-SECRET|MESSAGE-SECRET|password|message|config' \
        "${workdir}/artifacts/clusterpackage.json"; then
        fail "ClusterPackage configuration reached diagnostic artifacts"
    fi
)

test_diagnostics_are_bounded_and_status_preserving() (
    export ROSA_OPERATOR_INSTALL_TEST_MODE=true
    # shellcheck source=/dev/null
    source "${INSTALL_SCRIPT}"

    local workdir
    local fakebin
    workdir=$(mktemp -d)
    trap 'rm -rf "${workdir}"' EXIT
    fakebin="${workdir}/bin"
    mkdir "${fakebin}" "${workdir}/profile" "${workdir}/shared" "${workdir}/artifacts"
    printf '%s\n' 'test-token' > "${workdir}/profile/ocm-token"
    printf '%s\n' 'test-cluster' > "${workdir}/shared/cluster-id"

    cat > "${fakebin}/timeout" <<'EOF'
#!/bin/bash
printf '%s %s %s\n' "$1" "$2" "$3" >> "${TIMEOUT_LOG}"
shift
exec "$@"
EOF
    cat > "${fakebin}/ocm" <<'EOF'
#!/bin/bash
if [[ "$1" == "login" ]]; then
    exit 0
fi
if [[ "$2" == *"/external_configuration/syncsets" ]]; then
    jq -n '{total: 1, items: [{id: "safe-id", resources: [{kind: "Secret", data: {password: "OCM-SECRET"}}]}]}'
else
    jq -n '{resources: {cluster_sync: null}, secret: "OCM-LIVE-SECRET"}'
fi
EOF
    chmod +x "${fakebin}/timeout" "${fakebin}/ocm"
    PATH="${fakebin}:${PATH}"
    TIMEOUT_LOG="${workdir}/timeout.log"
    CLUSTER_PROFILE_DIR="${workdir}/profile"
    SHARED_DIR="${workdir}/shared"
    ARTIFACT_DIR="${workdir}/artifacts"
    OCM_DIAGNOSTIC_TIMEOUT=1s
    export PATH TIMEOUT_LOG CLUSTER_PROFILE_DIR SHARED_DIR ARTIFACT_DIR OCM_DIAGNOSTIC_TIMEOUT

    collect_hive_sync_state
    [[ "$(grep -c '^1s ocm ' "${TIMEOUT_LOG}")" -eq 3 ]] || fail "OCM calls were not all bounded by timeout"
    if grep -ERq 'OCM-SECRET|OCM-LIVE-SECRET|password' "${ARTIFACT_DIR}"; then
        fail "OCM resource payload reached diagnostic artifacts"
    fi

    collect_operator_logs() { return 99; }
    if ! (on_exit 0); then
        fail "EXIT diagnostics changed a successful status to failure"
    fi
    set +o errexit
    (on_exit 7)
    local status=$?
    set -o errexit
    [[ "${status}" -eq 7 ]] || fail "EXIT diagnostics changed status 7 to ${status}"
)

test_cleanup_restores_after_partial_failure() (
    export ROSA_OPERATOR_CLEANUP_TEST_MODE=true
    # shellcheck source=/dev/null
    source "${CLEANUP_SCRIPT}"

    local workdir
    local fakebin
    workdir=$(mktemp -d)
    trap 'rm -rf "${workdir}"' EXIT
    fakebin="${workdir}/bin"
    mkdir "${fakebin}"
    REQUIRED_CR_BACKUP_DIR="${workdir}/shared/operator-required-cr-backups"
    mkdir "${workdir}/shared"
    mkdir -m 0700 "${REQUIRED_CR_BACKUP_DIR}"
    jq -n '{apiVersion:"managed.openshift.io/v1alpha1",kind:"SubjectPermission",metadata:{name:"dedicated-admins",namespace:"openshift-config",ownerReferences:[{apiVersion:"apps/v1",kind:"Deployment",name:"valid-owner",uid:"valid-uid"}]},spec:{permissions:["admin"]}}' \
        > "${REQUIRED_CR_BACKUP_DIR}/0.json"
    jq -n '{apiVersion:"monitoring.openshift.io/v1",kind:"RouteMonitor",metadata:{name:"console"},spec:{target:"console"}}' \
        > "${REQUIRED_CR_BACKUP_DIR}/1.json"
    chmod 0600 "${REQUIRED_CR_BACKUP_DIR}"/*.json

    cat > "${fakebin}/oc" <<'EOF'
#!/bin/bash
count=0
[[ -f "${OC_COUNT}" ]] && count=$(cat "${OC_COUNT}")
count=$((count + 1))
printf '%s\n' "${count}" > "${OC_COUNT}"
if [[ "${count}" -eq 1 ]]; then
    exit 1
fi
if [[ "$1" == "patch" ]]; then
    printf '%s\n' "$7" >> "${OC_PATCH_LOG}"
    exit 0
fi
jq -r '(.kind // "unknown") + "/" + (.metadata.name // "unknown") + "/" + (.metadata.namespace // "cluster")' "$3" >> "${OC_APPLY_LOG}"
EOF
    chmod +x "${fakebin}/oc"
    PATH="${fakebin}:${PATH}"
    OC_COUNT="${workdir}/oc-count"
    OC_APPLY_LOG="${workdir}/oc-apply.log"
    OC_PATCH_LOG="${workdir}/oc-patch.log"
    REQUIRED_CR_RESTORE_ATTEMPTS=2
    REQUIRED_CR_RESTORE_RETRY_SECONDS=0
    export PATH OC_COUNT OC_APPLY_LOG OC_PATCH_LOG REQUIRED_CR_RESTORE_ATTEMPTS REQUIRED_CR_RESTORE_RETRY_SECONDS

    restore_required_cr_backups
    [[ ! -e "${REQUIRED_CR_BACKUP_DIR}" ]] || fail "full-payload backups were not deleted after restore"
    grep -Fqx 'SubjectPermission/dedicated-admins/openshift-config' "${OC_APPLY_LOG}" \
        || fail "namespaced required CR was not restored"
    grep -Fqx 'RouteMonitor/console/cluster' "${OC_APPLY_LOG}" \
        || fail "cluster-scoped required CR was not restored"
    grep -q 'valid-owner' "${OC_PATCH_LOG}" || fail "valid owner reference was not restored"
    restore_required_cr_backups
)

test_required_cr_parsing_and_sanitization
test_crd_diagnostics_exact_allowlist
test_diagnostics_are_bounded_and_status_preserving
test_cleanup_restores_after_partial_failure

echo "PASS: ROSA operator lifecycle and diagnostic sanitization"
