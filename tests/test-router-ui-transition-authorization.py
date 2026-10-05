#!/usr/bin/env python3
"""Exercise release transition authorization without building historical packages."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SUPPORTED_RCS = (5, 6, 14, 15, 16)


def block(path, expression):
    match = re.search(expression, path.read_text(), re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError("cannot locate release contract in " + path.name)
    return match.group(0)


class TransitionAuthorization(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.producer = block(
            ROOT / "scripts/stage-router-release.sh",
            r'^if \[ "\$RELEASE_CHANNEL" = candidate \] &&\n.*?'
            r'^  "\$ROOT_DIR/release/transition-matrix.json"\)"$',
        )
        cls.validator = block(
            ROOT / "scripts/validate-staged-release.sh",
            r'^if \[ "\$RELEASE_CHANNEL" = stable \]; then\n.*?^fi$',
        )

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="router-ui-transition-contract-")
        self.addCleanup(self.scratch.cleanup)
        self.manifest = Path(self.scratch.name) / "contract.json"

    def run_shell(self, script, env, expected=0):
        result = subprocess.run(
            ["sh", "-eu", "-c", script], env=dict(os.environ, **env),
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, expected, result.stderr)
        return result.stdout

    def identity(self, channel):
        # Exercise both supported target tuples even after a metadata-only
        # stable promotion; these are JSON contracts, never package fixtures.
        app, package = "0.7.11-rc.22", "0.7.11~rc22-1"
        if channel == "stable":
            app, package = "0.7.11", "0.7.11-1"
        return {"ROOT_DIR": str(ROOT), "APP_VERSION": app, "PKG_VERSION": package,
                "PREMIER_ROUTER_HOST_TEST": "1",
                "EXPECTED_CANDIDATE_APP_VERSION": app,
                "EXPECTED_CANDIDATE_PACKAGE_VERSION": package,
                "RELEASE_CHANNEL": channel, "MANIFEST": str(self.manifest)}

    def make_manifest(self, channel):
        env = self.identity(channel)
        transitions = json.loads(self.run_shell(
            self.producer + '\nprintf "%s\\n" "$TRANSITIONS_JSON"', env))
        document = {"app_version": env["APP_VERSION"],
                    "package_version": env["PKG_VERSION"], "transitions": transitions}
        self.manifest.write_text(json.dumps(document))
        return document, env

    def validate(self, env, expected=0):
        self.run_shell('fail() { echo "$*" >&2; exit 1; }\n' + self.validator,
                       env, expected)

    def test_rc7_is_explicitly_unsupported_without_rewriting_history(self):
        matrix = json.loads((ROOT / "release/transition-matrix.json").read_text())
        rc7 = [item for item in matrix["baselines"] if item["version"] == "0.7.11-rc.7"]
        self.assertEqual(len(rc7), 1)
        self.assertEqual(rc7[0]["support"], "unsupported")
        self.assertEqual(rc7[0]["tag_commit"], "97da893062ebed1e27e9b35dbf0b68f248c12dd7")
        self.assertEqual(rc7[0]["tree"], "db5e610c25eeda74f0ec0c931145249669eced69")

    def test_generated_contract_and_actual_runtime_authorization(self):
        for channel in ("candidate", "stable"):
            with self.subTest(channel=channel):
                document, env = self.make_manifest(channel)
                self.validate(env)
                expected = {("0.7.11-rc." + str(rc), 2) for rc in SUPPORTED_RCS}
                matrix = json.loads((ROOT / "release/transition-matrix.json").read_text())
                expected.update((row["version"], 1) for row in matrix["baselines"]
                                if row["published_release"])
                self.assertEqual({(row["source_version"], row["source_protocol"])
                                  for row in document["transitions"]}, expected)
                runtime = '. "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh"\n'
                for version, protocol in sorted(expected):
                    self.run_shell(runtime + 'pr_transition_supported "$MANIFEST" "$SOURCE" "$PROTOCOL"',
                                   dict(env, SOURCE=version, PROTOCOL=str(protocol)))
                for version in ("0.7.11-rc.7", "0.7.11-rc.18"):
                    self.run_shell(runtime + 'pr_transition_supported "$MANIFEST" "$SOURCE" 2',
                                   dict(env, SOURCE=version), expected=1)

    def test_validator_rejects_rc7_authorization_injection(self):
        for channel in ("candidate", "stable"):
            with self.subTest(channel=channel):
                document, env = self.make_manifest(channel)
                document["transitions"].append({"source_version": "0.7.11-rc.7",
                                                "source_protocol": 2, "mode": "package-v2-rc"})
                self.manifest.write_text(json.dumps(document))
                self.validate(env, expected=1)

    def test_validator_preserves_every_real_protocol2_baseline(self):
        for channel in ("candidate", "stable"):
            for rc in SUPPORTED_RCS:
                with self.subTest(channel=channel, removed_rc=rc):
                    document, env = self.make_manifest(channel)
                    document["transitions"] = [row for row in document["transitions"]
                                               if row["source_version"] != "0.7.11-rc." + str(rc)]
                    self.manifest.write_text(json.dumps(document))
                    self.validate(env, expected=1)


if __name__ == "__main__":
    unittest.main()
