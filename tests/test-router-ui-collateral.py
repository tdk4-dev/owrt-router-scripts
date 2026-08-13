#!/usr/bin/env python3
"""Build-free contract tests for manifest-driven Router UI collateral."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts/render-router-ui-install-guide.py"
MANIFEST = ROOT / "tests/fixtures/release/router-ui-0.7.11-rc10-provisional-manifest.json"
RULES = ROOT / "release/router-ui-release-rules.json"
TEMPLATE = ROOT / "docs/templates/router-ui-install-guide-template.json"
BOOTSTRAP = ROOT / "bootstrap-router-ui-ipk-install.sh"

source = GENERATOR.read_text(encoding="utf-8")
assert "/Users/" not in source and "/private/" not in source
assert not re.search(r"[0-9a-f]{64}", source), "generator must not embed package or source hashes"
assert "32768" not in source and "16384" not in source, "generator must not embed storage gates"

rules = json.loads(RULES.read_text(encoding="utf-8"))
bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
storage = rules["storage"]
assert f"PERSISTENT_REQUIRED_KIB=$(({storage['persistent_base_kib']} + (PACKAGE_KIB * {storage['persistent_package_multiplier']})))" in bootstrap
assert f"TEMPORARY_REQUIRED_KIB=$(({storage['temporary_base_kib']} + (PACKAGE_KIB * {storage['temporary_package_multiplier']})))" in bootstrap

result = subprocess.run([
    sys.executable, str(GENERATOR),
    "--manifest", str(MANIFEST),
    "--rules", str(RULES),
    "--template", str(TEMPLATE),
    "--mode", "fixture",
    "--validate-only",
], check=True, text=True, stdout=subprocess.PIPE)
facts = json.loads(result.stdout)
assert facts == {
    "manifest_sha256": facts["manifest_sha256"],
    "mode": "fixture",
    "ok": True,
    "persistent_kib": 33080,
    "temporary_kib": 16540,
    "total_bytes": 79872,
}

production = json.loads(MANIFEST.read_text(encoding="utf-8"))
production["production"] = True
production["collateral_status"] = "canonical-signed"
temporary = ROOT / "tmp/pdfs/test-canonical-manifest.json"
temporary.parent.mkdir(parents=True, exist_ok=True)
temporary.write_text(json.dumps(production), encoding="utf-8")
try:
    refused = subprocess.run([
        sys.executable, str(GENERATOR),
        "--manifest", str(temporary),
        "--rules", str(RULES),
        "--template", str(TEMPLATE),
        "--mode", "canonical",
        "--validate-only",
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert refused.returncode != 0
    assert "canonical mode requires signature proof" in refused.stderr
finally:
    temporary.unlink(missing_ok=True)

print("Manifest-driven collateral contract tests passed")
