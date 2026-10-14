# ROSA offline regression checks

Run `bash hack/rosa/validate-hcp-cr-status-credentials.sh` from the repository root.
The check executes the HCP CR status command script with temporary dummy
credential files and an isolated environment. It stubs curl, tar, OCM,
backplane, and oc; backplane login deliberately fails before elevation or
resource collection. No live login, network, cloud, or cluster calls occur.

The cases cover client and token formats, precedence, incomplete and empty
pairs, login failure, best-effort exits, and secret-free stdout/stderr with
tracing both disabled and enabled. `HCP_CR_STATUS_SCRIPT` can select another
script revision for regression reproduction. Assertions never print arguments
or captured output. This proves reader compatibility, not live credential
availability or end-to-end artifact collection.
