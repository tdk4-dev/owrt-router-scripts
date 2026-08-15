#!/usr/bin/env python3
"""Focused parsed-argument contracts for the Tier 0 collateral renderer guard."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts/render-router-ui-install-guide.py"
MANIFEST = ROOT / "tests/fixtures/release/router-ui-0.7.11-rc12-provisional-manifest.json"
RULES = ROOT / "release/router-ui-release-rules.json"
TEMPLATE = ROOT / "docs/templates/router-ui-install-guide-template.json"
BASE_ARGS = [
    sys.executable,
    str(GENERATOR),
    "--manifest",
    str(MANIFEST),
    "--rules",
    str(RULES),
    "--template",
    str(TEMPLATE),
    "--mode",
    "fixture",
]
FORBIDDEN_SUFFIXES = {
    ".pdf", ".ipk", ".img", ".gz", ".bin", ".trx", ".ubi", ".itb", ".iso", ".sig"
}


def artifact_inventory(root: Path) -> set[Path]:
    return {
        path.relative_to(root)
        for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() in FORBIDDEN_SUFFIXES
    }


def guarded_env(log: Path) -> dict[str, str]:
    environment = os.environ.copy()
    environment["ROUTER_UI_TIER0_GUARD_LOG"] = str(log)
    return environment


with tempfile.TemporaryDirectory(prefix="router-ui-tier0-renderer-", dir=os.environ.get("TMPDIR")) as raw:
    temporary = Path(raw)

    validation_log = temporary / "validation.guard.log"
    validation_log.touch()
    before = artifact_inventory(temporary)
    validation = subprocess.run(
        [*BASE_ARGS, "--validate-only"],
        env=guarded_env(validation_log),
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert json.loads(validation.stdout)["ok"] is True
    assert validation_log.read_bytes() == b""
    assert artifact_inventory(temporary) == before

    output_log = temporary / "output.guard.log"
    output_log.touch()
    output = temporary / "must-not-exist.pdf"
    before = artifact_inventory(temporary)
    refused_output = subprocess.run(
        [*BASE_ARGS, "--output", str(output)],
        env=guarded_env(output_log),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert refused_output.returncode == 97
    assert output_log.read_text(encoding="utf-8") == "staging:render-router-ui-install-guide.py\n"
    assert not output.exists()
    assert artifact_inventory(temporary) == before

    unguarded = os.environ.copy()
    unguarded.pop("ROUTER_UI_TIER0_GUARD_LOG", None)
    ambiguous_output = temporary / "ambiguous-must-not-exist.pdf"
    ambiguous = subprocess.run(
        [*BASE_ARGS, "--validate-only", "--output", str(ambiguous_output)],
        env=unguarded,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert ambiguous.returncode != 0
    assert "--validate-only cannot be combined with --output" in ambiguous.stderr
    assert not ambiguous_output.exists()

    canonical_manifest = temporary / "canonical-manifest.json"
    canonical = json.loads(MANIFEST.read_text(encoding="utf-8"))
    canonical["production"] = True
    canonical["collateral_status"] = "canonical-signed"
    canonical_manifest.write_text(json.dumps(canonical), encoding="utf-8")
    canonical_log = temporary / "canonical.guard.log"
    canonical_log.touch()
    canonical_validation = subprocess.run(
        [
            sys.executable,
            str(GENERATOR),
            "--manifest",
            str(canonical_manifest),
            "--rules",
            str(RULES),
            "--template",
            str(TEMPLATE),
            "--mode",
            "canonical",
            "--validate-only",
        ],
        env=guarded_env(canonical_log),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert canonical_validation.returncode != 0
    assert "canonical mode requires signature proof" in canonical_validation.stderr
    assert canonical_log.read_bytes() == b""
    assert artifact_inventory(temporary) == before

print("Tier 0 parsed renderer validation/output/signature guard contracts passed")
