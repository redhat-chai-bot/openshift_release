#!/usr/bin/env python3

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "ci-operator/step-registry/rosa/operator/install/rosa-operator-install-commands.sh"
SOURCE = SCRIPT.read_text()
FUNCTIONS = SOURCE.split("\nlog(){", 1)[0]
GATE = SOURCE.split('if [[ -n "${OPERATOR_REQUIRED_CRS:-}" ]]; then', 1)[1]
GATE = 'if [[ -n "${OPERATOR_REQUIRED_CRS:-}" ]]; then' + GATE.split(
    "# Wait for additional operator-managed deployments", 1
)[0]
SENTINEL = "SENSITIVE_SENTINEL_DO_NOT_EXPORT"
OBJECT = {
    "metadata": {
        "uid": "fixture-uid",
        "deletionTimestamp": "2026-01-01T00:00:00Z",
        "labels": {"hive.openshift.io/managed": "true", "private": SENTINEL},
        "annotations": {"private": SENTINEL,
                        "kubectl.kubernetes.io/last-applied-configuration": SENTINEL},
        "ownerReferences": [{"apiVersion": "v1", "kind": "Fixture",
                             "name": "fixture-owner", "uid": "owner-uid",
                             "controller": True, "blockOwnerDeletion": True,
                             "unexpected": SENTINEL}],
    },
    "spec": {"private": SENTINEL},
    "status": {"conditions": [{"type": "Established", "status": "True",
                               "reason": "Accepted", "message": SENTINEL}]},
}


class DiagnosticsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.artifacts = self.directory / "artifacts"
        self.calls = self.directory / "calls.jsonl"
        fixture = self.directory / "fixture.json"
        fixture.write_text(json.dumps(OBJECT))
        self.environment = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                                ARTIFACT_DIR=str(self.artifacts),
                                OPERATOR_CRDS=" fixtures.example.com ",
                                OPERATOR_REQUIRED_CRS=" fixtures.example.com/dedicated-admins ,"
                                                      "fixtures.example.com/other/test-namespace ",
                                MOCK_FIXTURE=str(fixture), MOCK_CALLS=str(self.calls),
                                MOCK_STATE="present")
        self.write_command("oc", '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import signal
import time

arguments = sys.argv[1:]
with open(os.environ["MOCK_CALLS"], "a") as calls:
    calls.write(json.dumps(arguments) + "\\n")
if "--ignore-not-found" not in arguments:
    if os.environ.get("MOCK_GATE_PRESENT") == "true" and arguments[1] == "fixtures.example.com":
        sys.exit(0)
    sys.exit(1)
state = os.environ["MOCK_STATE"]
if state == "resist-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(3)
if state == "missing":
    sys.exit(0)
if state in ("error", "forbidden", "unauthorized"):
    reason = {"error": "ServiceUnavailable", "forbidden": "Forbidden",
              "unauthorized": "Unauthorized"}[state]
    print("Error from server (" + reason + "): SENSITIVE_SENTINEL_DO_NOT_EXPORT", file=sys.stderr)
    sys.exit(7)
if state == "malformed":
    print("not json SENSITIVE_SENTINEL_DO_NOT_EXPORT")
else:
    print(Path(os.environ["MOCK_FIXTURE"]).read_text())
''')
        self.write_command("sleep", "#!/bin/bash\nexit 0\n")

    def write_command(self, name, content):
        command = self.bin / name
        command.write_text(content)
        command.chmod(0o755)

    def run_shell(self, commands):
        return subprocess.run(["bash", "-c", FUNCTIONS + "\nlog() { :; }\n" + commands],
                              env=self.environment, capture_output=True, text=True, timeout=20)

    def records(self, phase="pre-swap"):
        artifact = self.artifacts / "operator-resource-metadata" / f"{phase}.jsonl"
        return [json.loads(line) for line in artifact.read_text().splitlines()]

    def assert_sanitized(self, result):
        self.assertNotIn(SENTINEL, result.stdout + result.stderr)
        for artifact in self.artifacts.rglob("*"):
            if artifact.is_file():
                self.assertNotIn(SENTINEL, artifact.read_text())

    def test_present_exact_targets_allowlist_and_bounds(self):
        result = self.run_shell("collect_resource_metadata pre-swap || true")
        self.assertEqual(result.returncode, 0, result.stderr)
        records = self.records()
        self.assertEqual(len(records), 3)
        for record in records:
            self.assertEqual(record["state"], "present")
            self.assertEqual(record["uid"], "fixture-uid")
            self.assertEqual(record["deletionTimestamp"], OBJECT["metadata"]["deletionTimestamp"])
            self.assertEqual(record["hiveManaged"], "true")
            self.assertEqual(record["ownerReferences"][0]["name"], "fixture-owner")
            self.assertEqual(set(record), {"resource", "name", "namespace", "state", "exitCode",
                                         "uid", "deletionTimestamp", "ownerReferences", "hiveManaged"}
                             | ({"conditions"} if record["resource"] == "crd" else set()))
        self.assertEqual(records[-1]["conditions"],
                         [{"type": "Established", "status": "True", "reason": "Accepted"}])
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        metadata_calls = [call for call in calls if "--ignore-not-found" in call]
        self.assertEqual([call[1:3] for call in metadata_calls],
                         [["fixtures.example.com", "dedicated-admins"],
                          ["fixtures.example.com", "other"], ["crd", "fixtures.example.com"]])
        self.assertIn("-n", metadata_calls[1])
        self.assertIn("test-namespace", metadata_calls[1])
        for call in metadata_calls:
            self.assertIn("--request-timeout=10s", call)
            self.assertNotIn("-A", call)
        self.assert_sanitized(result)

    def test_missing_is_not_read_failure(self):
        for fixture_state, expected in [("missing", "missing"), ("error", "read_error"),
                                        ("forbidden", "access_denied"),
                                        ("unauthorized", "access_denied")]:
            with self.subTest(state=fixture_state):
                self.environment["MOCK_STATE"] = fixture_state
                result = self.run_shell(f"collect_resource_metadata {fixture_state} || true")
                self.assertEqual(result.returncode, 0, result.stderr)
                for record in self.records(fixture_state):
                    self.assertEqual(record["state"], expected)
                    self.assertEqual(record["exitCode"], 0 if fixture_state == "missing" else 7)
                    self.assertNotIn("uid", record)
                self.assert_sanitized(result)

    def test_phase_separation_and_original_exit_status(self):
        result = self.run_shell("collect_resource_metadata pre-swap || true\n"
                                "MOCK_STATE=missing collect_resource_metadata post-restore || true\n"
                                "MOCK_STATE=error collect_resource_metadata required-cr-timeout || true\n"
                                "exit 37")
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertEqual(self.records()[0]["state"], "present")
        self.assertEqual(self.records("post-restore")[0]["state"], "missing")
        self.assertEqual(self.records("required-cr-timeout")[0]["state"], "read_error")
        self.assert_sanitized(result)

    def test_artifact_dir_unset_does_not_read(self):
        self.environment.pop("ARTIFACT_DIR")
        result = self.run_shell("collect_resource_metadata pre-swap || true\nexit 37")
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.artifacts.exists())

    def test_collector_and_output_failures_preserve_exit(self):
        self.environment["MOCK_STATE"] = "malformed"
        result = self.run_shell("collect_resource_metadata malformed || true\nexit 37")
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertTrue(all(record["state"] == "collector_error"
                            for record in self.records("malformed")))
        self.assertEqual(self.records("malformed")[0]["name"], "dedicated-admins")
        self.assert_sanitized(result)
        self.write_command("jq", "#!/bin/bash\nexit 9\n")
        result = self.run_shell("collect_resource_metadata broken-jq || true\nexit 37")
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertEqual(self.records("broken-jq")[0]["state"], "collector_error")
        self.artifacts.mkdir(exist_ok=True)
        (self.artifacts / "operator-resource-metadata").rename(self.artifacts / "saved")
        (self.artifacts / "operator-resource-metadata").write_text("not a directory")
        result = self.run_shell("collect_resource_metadata unwritable || true\nexit 37")
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertIn("WARNING", result.stderr)

    def test_bounded_timeout_is_not_absence(self):
        self.write_command("timeout", '#!/bin/bash\n'
                           '[[ "$1" == "--kill-after=5s" && "$2" == "15s" ]] || exit 99\nexit 124\n')
        result = self.run_shell("collect_resource_metadata pre-swap || true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(record["state"] == "read_timeout" for record in self.records()))

    def test_forced_termination_is_bounded_and_preserves_exit(self):
        self.environment["MOCK_STATE"] = "resist-term"
        self.write_command("timeout", '#!/bin/bash\n'
                           '[[ "$1" == "--kill-after=5s" && "$2" == "15s" ]] || exit 99\n'
                           'shift 2\nexec /usr/bin/timeout --kill-after=0.1s 0.1s "$@"\n')
        started = time.monotonic()
        result = self.run_shell("collect_resource_metadata pre-swap || true\nexit 37")
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertTrue(all(record["state"] == "read_timeout" and record["exitCode"] == 137
                            for record in self.records()))

    def test_invalid_target_never_becomes_list_read(self):
        self.environment["OPERATOR_CRDS"] = ""
        self.environment["OPERATOR_REQUIRED_CRS"] = "fixtures.example.com/,fixtures.example.com/name/ns/extra"
        result = self.run_shell("collect_resource_metadata pre-swap || true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(record["reason"] == "invalid_target" for record in self.records()))
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertFalse(any("--ignore-not-found" in call for call in calls))

    def test_real_required_cr_gate_success(self):
        self.environment["MOCK_GATE_PRESENT"] = "true"
        result = self.run_shell(GATE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.artifacts / "operator-resource-metadata/required-cr-timeout.jsonl").exists())
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        lookups = [call for call in calls if call[1] == "fixtures.example.com"]
        self.assertEqual(lookups, [["get", "fixtures.example.com", "dedicated-admins"],
                                   ["get", "fixtures.example.com", "other", "-n", "test-namespace"]])

    def test_real_required_cr_gate_keeps_failure_and_poll_count(self):
        self.environment["MOCK_STATE"] = "missing"
        result = self.run_shell(GATE)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue(all(record["state"] == "missing"
                            for record in self.records("required-cr-timeout")))
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        polls = [call for call in calls if call[:3] == ["get", "fixtures.example.com", "dedicated-admins"]
                 and "--ignore-not-found" not in call]
        self.assertEqual(len(polls), 24)
        self.assert_sanitized(result)

    def test_hooks_precede_mutations_and_follow_restore(self):
        self.assertLess(SOURCE.index("collect_resource_metadata pre-swap || true"),
                        SOURCE.index('PACKAGES_TO_PAUSE=("${OPERATOR_NAME}")'))
        self.assertLess(SOURCE.index('for backup in "${CR_BACKUP_DIR}"/*.json; do'),
                        SOURCE.index("collect_resource_metadata post-restore || true"))
        self.assertLess(SOURCE.index("collect_resource_metadata post-restore || true"),
                        SOURCE.index('if [[ -n "${OPERATOR_REQUIRED_CRS:-}" ]]; then'))


if __name__ == "__main__":
    unittest.main(verbosity=2)
