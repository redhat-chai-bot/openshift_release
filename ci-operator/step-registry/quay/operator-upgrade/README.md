# Quay n-1 to n OLM operator upgrade scaffold

`quay-operator-upgrade-workflow` is a parameterized registry workflow, not a scheduled
job. A consuming ci-operator config must provide exact source and target
identities; this directory deliberately supplies no Quay or OpenShift version,
tag, channel, or floating catalog default.

The workflow order is:

1. `quay-install-odf-operator` provides the NooBaa CRD required by the existing
   `quay-install-quay` step.
2. `quay-operator-upgrade-install-source` creates an n-1 `CatalogSource` from
   `QUAY_UPGRADE_SOURCE_CATALOG_IMAGE`, requires its requested source channel,
   and records the Succeeded `installedCSV`.
3. `quay-install-quay`, `quay-operator-upgrade-prepare-e2e`, and
   `quay-create-admin-user` create a temporary Quay instance and its Playwright
   route/admin credentials.
4. `quay-operator-upgrade-smoke` is a thin wrapper around `quay-test-e2e` with
   a positive `PLAYWRIGHT_GREP` (default `@smoke`).
5. `quay-operator-upgrade-upgrade` creates the n catalog, changes both Subscription
   catalog source and channel, requires a different Succeeded `installedCSV`,
   and asserts QuayRegistry and quay-app readiness.
6. `quay-operator-upgrade-full` is the second thin `quay-test-e2e` wrapper;
   it runs the full target suite subject to the existing exclusion default.

## Required consumer values

```yaml
steps:
  env:
    QUAY_UPGRADE_SOURCE_CATALOG_IMAGE: quay.example.invalid/quay-catalog@sha256:<source digest>
    QUAY_UPGRADE_SOURCE_CHANNEL: <n-1 channel>
    QUAY_UPGRADE_TARGET_CATALOG_IMAGE: quay.example.invalid/quay-catalog@sha256:<target digest>
    QUAY_UPGRADE_TARGET_CHANNEL: <n channel>
    PLAYWRIGHT_N_MINUS_ONE_GIT_REPO: https://github.com/quay/quay.git
    PLAYWRIGHT_N_MINUS_ONE_GIT_BRANCH: <n-1 branch-tag-or-sha>
    PLAYWRIGHT_N_GIT_REPO: https://github.com/quay/quay.git
    PLAYWRIGHT_N_GIT_BRANCH: <n branch-tag-or-sha>
  workflow: quay-operator-upgrade-workflow
```

Catalog images must be digest pullspecs; unset, malformed, or identical source
and target identities fail before (or at the earliest safe point of) cluster
mutation. The wrapper chains set `PLAYWRIGHT_REQUIRE_EXPLICIT_REF=true`, so the
source phase cannot accidentally fall back to the target suite or vice versa.
`PLAYWRIGHT_N_MINUS_ONE_USE_IMAGE_TESTS` and `PLAYWRIGHT_N_USE_IMAGE_TESTS` are
available when an intentionally version-matched runner image is used instead.

The smoke and full wrappers use separate `PLAYWRIGHT_ARTIFACT_SUBDIR` values
(`n-minus-one-smoke` and `n-full`), preventing reports from overwriting one
another. They use unique reference identities whose command files are symlinks
to the existing `quay-test-e2e-commands.sh`, so the implementation is not
duplicated. They also select suite identity by `PLAYWRIGHT_PHASE`: the smoke wrapper consumes only
`PLAYWRIGHT_N_MINUS_ONE_*` and the full wrapper consumes only `PLAYWRIGHT_N_*`.
The base `PLAYWRIGHT_GREP_INVERT` default remains unchanged for both phases.

## Artifacts and assertions

The upgrade ref writes source/target identity, CSV comparison, pre/post
quay-app image lists, and a summary under `quay-operator-upgrade/`. On failure
it captures CatalogSource, Subscription, CSV, InstallPlan, QuayRegistry,
deployment, pod, and event diagnostics. A changed application image is reported
only when the pre/post image lists differ; a successful operator upgrade never
claims an application-version change that was not observed.

## Inner reference execution identity

The configresolver rejects a workflow that expands `quay-test-e2e` twice: it
reports `duplicate name: quay-test-e2e`. The wrappers therefore expand uniquely
named smoke/full adapter references whose command files symlink to the existing
implementation. This preserves one script while providing safe step identity;
the phase-specific environment and artifact subdirectories prevent suite and
artifact cross-talk.
