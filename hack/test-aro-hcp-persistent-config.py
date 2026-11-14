#!/usr/bin/env python3
"""Offline entrypoint checks; optionally use ARO_HCP_SOURCE_DIR and ARO_HCP_CONFIG_PROBE."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "ci-operator/step-registry/aro-hcp/test/persistent/aro-hcp-test-persistent-commands.sh"


class PersistentConfigTest(unittest.TestCase):
    def run_entrypoint(self, cloud, environment, profile, slot_environment=None, **extra):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            for name in ("bin", "test", "shared", "artifacts"):
                (work / name).mkdir()
            if slot_environment:
                (work / "shared/aro-hcp-slot.env").write_text("".join(
                    f"export {key}={shlex.quote(value)}\n"
                    for key, value in slot_environment.items()
                ))
            source = os.environ.get("ARO_HCP_SOURCE_DIR")
            if source:
                (work / "config").symlink_to(Path(source).resolve() / "config")
            else:
                (work / "config").mkdir()
                (work / "config/config.yaml").write_text("defaults: {}\n")
                (work / "config/config.msft.clouds-overlay.yaml").write_text("clouds: {}\n")
                (work / "config/config-dev-ci.yaml").write_text(
                    "clouds:\n  dev:\n    defaults:\n      ci:\n        int:\n"
                    "          mockIdentities:\n            msiMock:\n"
                    "              applicationName: example-mock\n"
                )
            (work / "bin/az").write_text(
                '#!/bin/bash\nif [[ "$1 $2" == "ad sp" ]]; then\n'
                '  echo 11111111-1111-1111-1111-111111111111\nfi\n'
            )
            (work / "test/aro-hcp-tests").write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, subprocess, sys\n"
                "probe = os.environ.get('ARO_HCP_CONFIG_PROBE')\n"
                "if probe:\n"
                "    subprocess.run([probe], check=True)\n"
                "keys = ['ARO_HCP_CLOUD', 'DEPLOY_ENV', 'VAULT_SECRET_PROFILE',\n"
                "        'CLUSTER_PROFILE_DIR', 'REGION', 'ARO_HCP_CONFIG_FILE',\n"
                "        'ARO_HCP_CONFIG_FILE_OVERRIDE', 'MI_MOCK_PRINCIPAL_ID']\n"
                "with open(os.environ['CAPTURE'], 'w') as output:\n"
                "    json.dump({key: os.environ.get(key, '') for key in keys}, output)\n"
            )
            for executable in (work / "bin/az", work / "test/aro-hcp-tests"):
                executable.chmod(0o755)
            env = {
                "PATH": f"{work / 'bin'}:{os.environ['PATH']}",
                "SHARED_DIR": str(work / "shared"),
                "ARTIFACT_DIR": str(work / "artifacts"),
                "CAPTURE": str(work / "capture.json"),
                "ARO_HCP_CLOUD": cloud,
                "ARO_HCP_DEPLOY_ENV": environment,
                "VAULT_SECRET_PROFILE": profile,
                "LOCATION": "westus3",
                "ARO_HCP_SUITE_NAME": "stage/parallel/all",
                "ARO_HCP_MAX_CONCURRENCY": "1",
                **extra,
            }
            if os.environ.get("ARO_HCP_CONFIG_PROBE"):
                env["ARO_HCP_CONFIG_PROBE"] = os.environ["ARO_HCP_CONFIG_PROBE"]
            wrapper = '''
cat() {
    case "$1" in
        /var/run/*) printf '%s\\n' offline-placeholder ;;
        *) command cat "$@" ;;
    esac
}
export -f cat
exec bash "$1"
'''
            result = subprocess.run(
                ["bash", "-c", wrapper, "offline-test", str(SCRIPT)],
                cwd=work, env=env, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            captured = json.loads((work / "capture.json").read_text())
            self.assertEqual(captured["VAULT_SECRET_PROFILE"], profile)
            expected_profile = (slot_environment or {}).get("SELECTED_CLUSTER_PROFILE_DIR", f"/var/run/aro-hcp-{profile}")
            self.assertEqual(captured["CLUSTER_PROFILE_DIR"], expected_profile)
            self.assertEqual(captured["ARO_HCP_CONFIG_FILE"], str(work / "config/config.yaml"))
            captured["ARO_HCP_CONFIG_FILE_OVERRIDE"] = captured["ARO_HCP_CONFIG_FILE_OVERRIDE"].replace(str(work), "$WORK")
            return captured

    def test_public_environments_use_config_names_and_overlay(self):
        for environment, profile in (("stg", "stg-rh"), ("int", "int-rh"), ("prod", "prod-rh"), ("prod", "prod")):
            with self.subTest(environment=environment, profile=profile):
                captured = self.run_entrypoint("public", environment, profile)
                self.assertEqual(captured["ARO_HCP_CLOUD"], "public")
                self.assertEqual(captured["DEPLOY_ENV"], environment)
                self.assertEqual(captured["ARO_HCP_CONFIG_FILE_OVERRIDE"], "$WORK/config/config.msft.clouds-overlay.yaml")
                self.assertEqual(bool(captured["MI_MOCK_PRINCIPAL_ID"]), environment == "int")

    def test_dev_config_and_empty_cloud_default(self):
        for cloud in ("dev", ""):
            with self.subTest(cloud=cloud):
                captured = self.run_entrypoint(cloud, "pers", "dev")
                self.assertEqual(captured["ARO_HCP_CLOUD"], "dev")
                self.assertEqual(captured["DEPLOY_ENV"], "pers")
                self.assertEqual(captured["ARO_HCP_CONFIG_FILE_OVERRIDE"], "")

    def test_explicit_overlay_and_principal_preserved(self):
        source = os.environ.get("ARO_HCP_SOURCE_DIR")
        overlay = str(Path(source).resolve() / "config/config.msft.clouds-overlay.yaml") if source else "/custom/overlay.yaml"
        captured = self.run_entrypoint(
            "public", "stg", "stg-rh", ARO_HCP_CONFIG_FILE_OVERRIDE=overlay,
            MI_MOCK_PRINCIPAL_ID="22222222-2222-2222-2222-222222222222",
        )
        self.assertEqual(captured["ARO_HCP_CONFIG_FILE_OVERRIDE"], overlay)
        self.assertEqual(captured["MI_MOCK_PRINCIPAL_ID"], "22222222-2222-2222-2222-222222222222")

    def test_location_override_preserved(self):
        captured = self.run_entrypoint("public", "stg", "stg-rh", MULTISTAGE_PARAM_OVERRIDE_LOCATION="uksouth")
        self.assertEqual(captured["REGION"], "uksouth")

    def test_slot_environment_precedence(self):
        slot_environment = {
            "ARO_HCP_DEPLOY_ENV": "prod",
            "SELECTED_CLUSTER_PROFILE_DIR": "/var/run/aro-hcp-prod-rh",
            "SELECTED_LOCATION": "westus3",
            "CUSTOMER_SUBSCRIPTION": "offline subscription",
        }
        for override in ("", "uksouth"):
            with self.subTest(location_override=override):
                captured = self.run_entrypoint(
                    "public", "stg", "stg-rh", slot_environment=slot_environment,
                    LOCATION="unused-location", MULTISTAGE_PARAM_OVERRIDE_LOCATION=override,
                )
                self.assertEqual(captured["ARO_HCP_CLOUD"], "public")
                self.assertEqual(captured["DEPLOY_ENV"], "prod")
                self.assertEqual(captured["REGION"], override or "westus3")
                self.assertEqual(captured["ARO_HCP_CONFIG_FILE_OVERRIDE"], "$WORK/config/config.msft.clouds-overlay.yaml")


if __name__ == "__main__":
    if not shutil.which("yq"):
        raise SystemExit("yq is required to exercise the actual entrypoint lookup")
    unittest.main()
