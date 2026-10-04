#!/usr/bin/env python3
"""Verify explicit package-candidate identity; never build, sign, or publish."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

PACKAGES = ("premier-router-core", "luci-app-premier-router", "premier-router-setup")
KEY_ID = "production-2026-07"
FINGERPRINT = "d055711acf1d9a5b"
TUPLES = {
    ("0.7.11-rc.20", "0.7.11~rc20-1", "candidate"),
    ("0.7.11", "0.7.11-1", "stable"),
}
PACKAGE_ONLY_ASSETS = frozenset("""
router-release-manifest.json router-release-manifest.json.sig
release-provenance.json release-provenance.json.sig SHA256SUMS SHA256SUMS.sig
router-ui-packages.txt INSTALLATION-RECOVERY.md RELEASE-NOTES.md
install-router-ui-release.sh install-router-ui-release.sh.sha256
bootstrap-router-ui-ipk-install.sh bootstrap-router-ui-ipk-install.sh.sha256
rescue-router-ui.sh rescue-router-ui.sh.sha256 luci-vpn-ui.tar.gz
luci-vpn-ui.tar.gz.sha256 vpn-ui-version.txt vpn-ui-changelog.txt
vpn-ui-release-date.txt router-candidate-validator router-update-supervisor
router-update-lib.sh 0.7.9-_35_vpn.js rd23-storage-geometry.json
installed-manifest.json installed-manifest.json.sig trusted-keys.json
release-signing-key-id historical-rescue-support-matrix.json
historical-rescue-support-matrix.md
""".split())


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def verify_source(root, source_sha, source_tree, app, package, channel):
    require((app, package, channel) in TUPLES, "unsupported expected identity tuple")
    require(re.fullmatch(r"[0-9a-f]{40}", source_sha), "source SHA must be exact")
    require(git(root, "rev-parse", "HEAD") == source_sha, "source SHA mismatch")
    tree = git(root, "rev-parse", "HEAD^{tree}")
    require(not source_tree or tree == source_tree, "source tree mismatch")
    require(not git(root, "status", "--porcelain"), "source checkout must be clean")
    for name, expected in (("VERSION", app), ("PACKAGE_VERSION", package),
                           ("files/usr/share/vpn-ui/version", app)):
        require((root / "luci-vpn-ui" / name).read_text().strip() == expected,
                "source version mismatch: " + name)
    registry = json.loads((root / "release/keys/trusted-keys.json").read_text())
    active = [item for item in registry["keys"] if item["status"] == "active"]
    require(registry["active_key_id"] == KEY_ID and len(active) == 1,
            "production active key mismatch")
    require(active[0]["key_id"] == KEY_ID and active[0]["fingerprint"] == FINGERPRINT,
            "production fingerprint mismatch")
    return {"schema_version": 1, "kind": "router-ui-package-candidate",
            "source_sha": source_sha, "source_tree": tree,
            "source_date_epoch": int(git(root, "show", "-s", "--format=%ct", "HEAD")),
            "app_version": app, "package_version": package, "channel": channel,
            "signing_key_id": KEY_ID, "signing_key_fingerprint": FINGERPRINT,
            "scope": "package-only", "vm_qualified": False,
            "hardware_qualified": False, "publication_authorized": False}


def verify_package_only(release, identity):
    require(release.is_dir() and not release.is_symlink(), "release directory is missing or symlinked")
    files = list(release.iterdir())
    require(all(p.is_file() and not p.is_symlink() for p in files), "release must contain only flat regular files")
    expected = {f"{name}_{identity['package_version']}_all.ipk" for name in PACKAGES}
    require({p.name for p in files if p.suffix == ".ipk"} == expected,
            "release must contain exactly the three expected IPKs")
    allowed = PACKAGE_ONLY_ASSETS | expected | {
        f"{identity['channel']}-channel.json", f"{identity['channel']}-channel.json.sig",
        f"premier-router-opkg-feed-{identity['app_version']}.tar.gz",
        KEY_ID + ".pub", KEY_ID + ".fingerprint"}
    require({p.name for p in files} <= allowed,
            "package-only release contains an unapproved asset")
    manifest = json.loads((release / "router-release-manifest.json").read_text())
    provenance = json.loads((release / "release-provenance.json").read_text())
    require(manifest.get("images") == [] and provenance.get("derived_images") == [],
            "package-only metadata contains images")
    for document in (manifest, provenance):
        for field in ("app_version", "package_version", "signing_key_id", "signing_key_fingerprint"):
            require(document.get(field) == identity[field], "artifact identity mismatch: " + field)
        require(document.get("source_commit") == identity["source_sha"] and
                document.get("source_dirty") is False, "artifact source mismatch")
    require(manifest.get("channel") == identity["channel"], "artifact channel mismatch")
    require(manifest.get("release_tag") == "vpn-panel-v" + identity["app_version"],
            "artifact tag identity mismatch")
    packages = manifest.get("packages", [])
    require([p.get("name") for p in packages] == list(PACKAGES), "manifest package list mismatch")
    for package in packages:
        filename = f"{package['name']}_{identity['package_version']}_all.ipk"
        require(package.get("filename") == filename, "manifest package filename mismatch")
        path = release / filename
        require(package.get("size") == path.stat().st_size and
                package.get("sha256") == sha256(path), "package size or checksum mismatch")
    return packages


def require_signature_inputs(release, channel):
    # Presence is only an early boundary check. The existing staged validator
    # derives the public fingerprint and verifies every signature cryptographically.
    for name in ("router-release-manifest.json", "release-provenance.json", "SHA256SUMS",
                 "installed-manifest.json", channel + "-channel.json"):
        for filename in (name, name + ".sig"):
            path = release / filename
            require(path.is_file() and not path.is_symlink() and path.stat().st_size > 0,
                    "missing or empty signature input: " + filename)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("source", "artifacts"))
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--source-tree")
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--package-version", required=True)
    parser.add_argument("--channel", required=True, choices=("candidate", "stable"))
    parser.add_argument("--release-dir", type=Path)
    parser.add_argument("--usign-bin", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    identity = verify_source(root, args.source_sha, args.source_tree,
                             args.app_version, args.package_version, args.channel)
    if args.mode == "artifacts":
        require(not os.environ.get("ROUTER_UI_TIER0_GUARD_LOG"), "artifact verification is outside Tier 0")
        require(args.release_dir and args.release_dir.is_absolute(), "release directory must be absolute")
        require(args.usign_bin and args.usign_bin.is_absolute() and args.usign_bin.is_file(),
                "absolute usign binary is required")
        packages = verify_package_only(args.release_dir, identity)
        require_signature_inputs(args.release_dir, args.channel)
        env = dict(os.environ, RELEASE_DIR=str(args.release_dir), USIGN_BIN=str(args.usign_bin),
                   STRICT_RELEASE="1", REQUIRE_IMAGES="0", REQUIRE_MAIN_ANCESTRY="0",
                   RELEASE_CHANNEL=args.channel, EXPECTED_SOURCE_COMMIT=args.source_sha,
                   EXPECTED_RELEASE_KEY_ID=KEY_ID, EXPECTED_CANDIDATE_APP_VERSION=args.app_version,
                   EXPECTED_CANDIDATE_PACKAGE_VERSION=args.package_version)
        # Validation uses temporary scratch space only; staged inputs are never modified.
        subprocess.run([str(root / "scripts/validate-staged-release.sh")], env=env,
                       check=True, stdout=sys.stderr)
        identity.update(packages=packages, signed_artifacts_verified=True,
                        manifest_sha256=sha256(args.release_dir / "router-release-manifest.json"),
                        checksums_sha256=sha256(args.release_dir / "SHA256SUMS"))
    print(json.dumps(identity, sort_keys=True, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print("PACKAGE-CANDIDATE-ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
