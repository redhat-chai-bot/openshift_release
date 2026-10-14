from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "ci-operator/step-registry/rosa/gather/hcp-cr-status/rosa-gather-hcp-cr-status-commands.sh"


class CollectionStatusTest(unittest.TestCase):
    def run_collection(self, scenario, guest=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for directory in ("bin", "shared", "artifacts", "credentials", "home"):
                (root / directory).mkdir()
            source = SCRIPT.read_text()
            self.assertEqual(source.count('CRED_DIR="/usr/local/cs-qe-credentials"'), 1)
            source = source.replace('CRED_DIR="/usr/local/cs-qe-credentials"', f'CRED_DIR="{root}/credentials"')
            script = root / "commands.sh"
            script.write_text(source)
            if scenario != "missing_cluster_id":
                (root / "shared/cluster-id").write_text("fake-cluster")
            if scenario != "missing_credentials":
                (root / "credentials/ocm-token").write_text("fake-sensitive-token")
            if guest:
                (root / "shared/guest-kubeconfig").write_text("fake-sensitive-kubeconfig")
            commands = {
                "curl": 'exit "${DOWNLOAD_RESULT:-0}"',
                "tar": '''if [[ "$SCENARIO" == extract_failed ]]; then exit 1; fi
while [[ "$1" != -C ]]; do shift; done
shift
printf '#!/bin/bash\\nif [[ "$1" == elevate && "$SCENARIO" == elevate_failed ]]; then exit 1; fi\\nexit "${BACKPLANE_RESULT:-0}"\\n' > "$1/ocm-backplane"
''',
                "ocm": 'exit "${LOGIN_RESULT:-0}"',
                "oc": '''if [[ "$*" == whoami ]]; then echo fake-user; exit "${WHOAMI_RESULT:-0}"; fi
if [[ "$*" == *"-o json"* ]]; then
  if [[ "$SCENARIO" == discovery_failed ]]; then exit 1; fi
  echo '{"items":[{"metadata":{"name":"fake-cluster","namespace":"fake-namespace"}}]}'
  exit 0
fi
if [[ "$SCENARIO" == all_failed || ( "$SCENARIO" == partial && "$*" == *nodepools* ) || ( "$SCENARIO" == guest_failed && "$*" == *certificatesigningrequests* ) ]]; then
  echo fake-sensitive-error >&2; exit 1
fi
if [[ "$SCENARIO" == empty ]]; then exit 0; fi
printf 'apiVersion: v1\\nitems: []\\n'
''',
            }
            for name, body in commands.items():
                command = root / "bin" / name
                command.write_text("#!/bin/bash\n" + body + "\n")
                command.chmod(0o755)
            environment = {
                "PATH": f"{root}/bin:/usr/bin:/bin",
                "HOME": str(root / "home"),
                "SHARED_DIR": str(root / "shared"),
                "ARTIFACT_DIR": str(root / "artifacts"),
                "OCM_LOGIN_ENV": "fake-environment",
                "SCENARIO": scenario,
                "DOWNLOAD_RESULT": "1" if scenario == "download_failed" else "0",
                "LOGIN_RESULT": "1" if scenario == "login_failed" else "0",
                "BACKPLANE_RESULT": "1" if scenario == "backplane_failed" else "0",
                "WHOAMI_RESULT": "1" if scenario == "whoami_failed" else "0",
            }
            result = subprocess.run(["/bin/bash", str(script)], env=environment, capture_output=True, text=True, timeout=15, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            status_text = (root / "artifacts/cr-status/collection-status.txt").read_text()
            for sensitive in ("fake-sensitive", "fake-cluster", "fake-namespace", "fake-user", str(root)):
                self.assertNotIn(sensitive, status_text)
            self.assertNotIn("CR status collection complete.", result.stdout)
            return dict(line.split("=", 1) for line in status_text.splitlines()), result.stdout

    def test_early_failures(self):
        for scenario, stage in (("missing_cluster_id", "missing_cluster_id"), ("missing_credentials", "missing_credentials"), ("download_failed", "download_cli"), ("extract_failed", "extract_cli"), ("login_failed", "ocm_login"), ("backplane_failed", "backplane_login"), ("elevate_failed", "backplane_elevate")):
            with self.subTest(scenario=scenario):
                status, output = self.run_collection(scenario)
                self.assertEqual(status["status"], "no_data")
                self.assertEqual(status["stage"], stage)
                self.assertEqual(status["attempted"], "0")
                self.assertIn("NO DATA", output)

    def test_collection_results(self):
        for scenario, expected, succeeded, failed in (("all_failed", "no_data", "0", "9"), ("partial", "partial", "8", "1"), ("empty", "no_data", "0", "9"), ("success", "complete", "9", "0"), ("whoami_failed", "partial", "9", "0"), ("discovery_failed", "partial", "9", "0")):
            with self.subTest(scenario=scenario):
                status, output = self.run_collection(scenario)
                self.assertEqual(status["status"], expected)
                self.assertEqual(status["succeeded"], succeeded)
                self.assertEqual(status["failed"], failed)
                self.assertEqual(status["attempted"], "9")
                self.assertEqual(status["guest"], "skipped_no_kubeconfig")
                self.assertEqual(status["limitations"], "1" if scenario in ("whoami_failed", "discovery_failed") else "0")
                if expected == "partial":
                    self.assertIn("PARTIAL", output)

    def test_guest_collection(self):
        for scenario, expected, succeeded in (("success", "complete", "11"), ("guest_failed", "partial", "10")):
            with self.subTest(scenario=scenario):
                status, _ = self.run_collection(scenario, guest=True)
                self.assertEqual(status["status"], expected)
                self.assertEqual(status["succeeded"], succeeded)
                self.assertEqual(status["attempted"], "11")
                self.assertEqual(status["guest"], "attempted")


if __name__ == "__main__":
    unittest.main()
