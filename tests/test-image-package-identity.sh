#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILDER="$ROOT_DIR/build-openwrt-custom-image-linux.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/release-vpn-panel.yml"

grep -q 'PROJECT_PACKAGE_DIR' "$BUILDER"
grep -q 'PROJECT_PACKAGE_MANIFEST' "$BUILDER"
grep -q 'Missing prebuilt project package' "$BUILDER"
grep -q 'ImageBuilder contains stale project IPKs' "$BUILDER"
grep -q 'rm -rf "$TARGET_OUT"' "$BUILDER"
grep -q 'project-ipk-sha256sums' "$BUILDER"
grep -q 'router-ui-packages.txt' "$BUILDER"
grep -q 'image-provenance.json' "$BUILDER"
grep -q 'UPDATER_PROTOCOL' "$ROOT_DIR/scripts/build-openwrt-ipks.sh"
! grep -q 'build-openwrt-ipks.sh' "$BUILDER"

grep -q 'uses: actions/download-artifact@v4' "$WORKFLOW"
grep -q 'name: canonical-router-ui-ipks' "$WORKFLOW"
grep -q 'PROJECT_PACKAGE_DIR:' "$WORKFLOW"
grep -q 'REQUIRE_IMAGES: "1"' "$WORKFLOW"
grep -q 'rd23-stock' "$WORKFLOW"
grep -q 'rd23-ubootmod' "$WORKFLOW"
grep -q 'x86-64' "$WORKFLOW"

# Only the root redirect is an image-specific overlay. Project application
# paths are owned by the canonical IPKs and may not be copied into the image.
overlay_copy_lines="$(sed -n '/^rm -rf "$OVERLAY"/,/^PACKAGES=/p' "$BUILDER" | grep -E 'cp .*OVERLAY' || true)"
printf '%s\n' "$overlay_copy_lines" | grep -q 'www/index.html'
[ "$(printf '%s\n' "$overlay_copy_lines" | grep -c '^' | tr -d ' ')" = 1 ]

printf 'Image pipeline consumes canonical IPKs and records package identity\n'
