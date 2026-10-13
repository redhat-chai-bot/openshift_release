#!/usr/bin/env python3

import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
COMMANDS = REPO / "ci-operator/step-registry/rosa/e2e/ocm-fvt/rosa-e2e-ocm-fvt-commands.sh"
SELECTED = "syntheticselected00000001"
OTHER = "syntheticunrelated0000002"
KUBECONFIG = "apiVersion: v1\nkind: Config\n"


class GuestKubeconfigTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.output = self.root / "output"
        self.shared = self.root / "shared"
        self.artifacts = self.root / "artifacts"
        self.configs = self.output / ".datainfo/kube-configs"
        for directory in (self.configs, self.shared, self.artifacts):
            directory.mkdir(parents=True)
        source = COMMANDS.read_text(encoding="utf-8")
        self.script = self.root / "publish.sh"
        self.script.write_text(
            "set -euo pipefail\n" + source[source.index("# Exit code for post-steps"):],
            encoding="utf-8",
        )

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def select(self, cluster_id=SELECTED):
        self.write(self.output / "profile/cluster.ini", f"ID = {cluster_id}\n")

    def run_publish(self, expected_config, cluster_id=SELECTED, exit_code=23):
        result = subprocess.run(
            ["bash", "-c", 'ocm_fvt_output="$1"; exit_code="$2"; source "$3"',
             "publish", str(self.output), str(exit_code), str(self.script)],
            env=dict(os.environ, SHARED_DIR=str(self.shared),
                     ARTIFACT_DIR=str(self.artifacts), OCM_FVT_DEFER_CLEAN="true",
                     OCM_FVT_JOB_NAME="synthetic-job"),
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
        self.assertEqual((self.shared / "ocm-fvt-exit-code").read_text(), f"{exit_code}\n")
        if cluster_id is not None:
            self.assertEqual((self.shared / "cluster-id").read_text().strip(), cluster_id)
        config = self.shared / "kubeconfig"
        if expected_config is None:
            self.assertFalse(config.exists(), result.stdout)
            self.assertIn("WARNING: no matching usable guest kubeconfig", result.stdout)
        else:
            self.assertEqual(config.read_text(), expected_config)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        self.assertTrue((self.shared / "ocm-fvt-clean-state.tgz").is_file())
        self.assertEqual((self.shared / "ocm-fvt-job-name").read_text(), "synthetic-job")
        self.assertEqual((self.artifacts / "ocm-fvt-job-name").read_text(), "synthetic-job")
        self.assertEqual((self.artifacts / "ocm-fvt-clean-state.tgz").read_bytes(),
                         (self.shared / "ocm-fvt-clean-state.tgz").read_bytes())
        if (self.output / "profile/cluster.ini").exists():
            with tarfile.open(self.shared / "ocm-fvt-clean-state.tgz") as archive:
                self.assertIn("profile/cluster.ini", archive.getnames())
        print(f"{self._testMethodName}: FVT exit={result.returncode}; guest={'absent' if expected_config is None else 'matched'}")

    def test_wrong_cluster_first(self):
        self.write(self.configs / f"{OTHER}.kubeconfig", KUBECONFIG + "wrong: true\n")
        self.select()
        self.write(self.configs / f"{SELECTED}.kubeconfig", KUBECONFIG)
        self.run_publish(KUBECONFIG)

    def test_matching_config(self):
        self.select()
        self.write(self.configs / f"{SELECTED}.kubeconfig", KUBECONFIG)
        self.run_publish(KUBECONFIG, exit_code=0)

    def test_missing_match(self):
        self.select()
        self.write(self.configs / f"{OTHER}.kubeconfig", KUBECONFIG)
        self.run_publish(None)

    def test_empty_match(self):
        self.select()
        self.write(self.configs / f"{SELECTED}.kubeconfig", "")
        self.run_publish(None)

    def test_invalid_match(self):
        self.select()
        self.write(self.configs / f"{SELECTED}.kubeconfig", "scrubbed placeholder\n")
        self.write(self.configs / f"{OTHER}.kubeconfig", KUBECONFIG)
        self.run_publish(None)

    def test_generic_config_not_correlated(self):
        self.select()
        self.write(self.output / "kubeconfig", KUBECONFIG)
        self.run_publish(None)

    def test_preexisting_id_is_authoritative(self):
        self.select(OTHER)
        self.write(self.shared / "cluster-id", SELECTED)
        self.write(self.configs / f"{OTHER}.kubeconfig", KUBECONFIG + "wrong: true\n")
        self.write(self.configs / f"{SELECTED}.kubeconfig", KUBECONFIG)
        self.run_publish(KUBECONFIG)

    def test_preexisting_wrong_config_replaced(self):
        self.select()
        self.write(self.shared / "kubeconfig", KUBECONFIG + "wrong: true\n")
        self.write(self.configs / f"{SELECTED}.kubeconfig", KUBECONFIG)
        self.run_publish(KUBECONFIG)

    def test_preexisting_matching_pair_preserved(self):
        self.write(self.shared / "cluster-id", SELECTED)
        self.write(self.shared / "kubeconfig", KUBECONFIG)
        self.write(self.configs / f"{SELECTED}.kubeconfig", KUBECONFIG)
        self.run_publish(KUBECONFIG)

    def test_unverifiable_preexisting_pair_removed(self):
        self.write(self.shared / "cluster-id", SELECTED)
        self.write(self.shared / "kubeconfig", KUBECONFIG)
        self.run_publish(None)

    def test_filename_id_fallback(self):
        self.write(self.configs / f"{SELECTED}.kubeconfig", KUBECONFIG)
        self.run_publish(KUBECONFIG)

    def test_no_id_removes_preexisting_config(self):
        self.write(self.shared / "kubeconfig", KUBECONFIG)
        self.run_publish(None, cluster_id=None)

    def test_missing_config_directory(self):
        self.select()
        self.configs.rmdir()
        self.write(self.shared / "kubeconfig", KUBECONFIG)
        self.run_publish(None)


if __name__ == "__main__":
    unittest.main()
