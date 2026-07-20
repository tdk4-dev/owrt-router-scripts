#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILDER="$ROOT_DIR/build-openwrt-custom-image-linux.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/release-vpn-panel.yml"
CANDIDATE_WORKFLOW="$ROOT_DIR/.github/workflows/validate-router-ui-candidate.yml"
VM_GATE="$ROOT_DIR/tests/vm/router-ui-vm-gate.sh"
VM_GUEST="$ROOT_DIR/tests/vm/router-ui-vm-guest.sh"

grep -q 'PROJECT_PACKAGE_DIR' "$BUILDER"
grep -q 'PROJECT_PACKAGE_MANIFEST' "$BUILDER"
grep -q 'Missing prebuilt project package' "$BUILDER"
grep -q 'ImageBuilder contains stale project IPKs' "$BUILDER"
grep -q 'rm -rf "$TARGET_OUT"' "$BUILDER"
grep -q 'project-ipk-sha256sums' "$BUILDER"
grep -q 'router-ui-packages.txt' "$BUILDER"
grep -q 'image-provenance.json' "$BUILDER"
grep -q 'INSTALLED_PACKAGE_SET_DIR' "$BUILDER"
grep -q 'project-payload-sha256sums' "$BUILDER"
grep -q 'overlay-files.txt' "$BUILDER"
grep -q 'profile-info.txt' "$BUILDER"
grep -q 'CONFIG_TARGET_ROOTFS_EXT4FS is not set' "$BUILDER"
grep -q 'squashfs-combined.img.gz' "$BUILDER"
grep -q 'rm -f "$pkg_dir/Packages" "$pkg_dir/Packages.gz" "$pkg_dir/Packages.sig"' "$BUILDER"
! grep -q 'ipkg-make-index.sh packages' "$BUILDER"
grep -q 'UPDATER_PROTOCOL' "$ROOT_DIR/scripts/build-openwrt-ipks.sh"
! grep -q 'build-openwrt-ipks.sh' "$BUILDER"
grep -q '! -name SHA256SUMS' "$ROOT_DIR/scripts/stage-installed-package-set.sh"
grep -q 'sha256sum -c SHA256SUMS' "$ROOT_DIR/scripts/stage-installed-package-set.sh"

grep -q 'uses: actions/download-artifact@v4' "$WORKFLOW"
grep -q 'name: canonical-router-ui-ipks' "$WORKFLOW"
grep -q 'PROJECT_PACKAGE_DIR:' "$WORKFLOW"
grep -q 'REQUIRE_IMAGES: "1"' "$WORKFLOW"
grep -q 'rd23-stock' "$WORKFLOW"
grep -q 'rd23-ubootmod' "$WORKFLOW"
grep -q 'profile: xiaomi_mi-router-ax3000t$' "$WORKFLOW"
! grep -q 'profile: xiaomi_mi-router-ax3000t-stock' "$WORKFLOW"
grep -q 'x86-64' "$WORKFLOW"
grep -q '^  vm-gate:' "$WORKFLOW"
grep -q 'router-ui-vm-gate.sh' "$WORKFLOW"
grep -q 'pretag-router-ui-candidate-' "$WORKFLOW"

grep -q 'source_sha:' "$CANDIDATE_WORKFLOW"
grep -q 'environment: router-ui-production-signing' "$CANDIDATE_WORKFLOW"
grep -q 'ROOTFS_PARTSIZE:' "$CANDIDATE_WORKFLOW"
grep -q 'WRITABLE_BUDGET_KIB:' "$CANDIDATE_WORKFLOW"
grep -q 'router-ui-vm-gate.sh' "$CANDIDATE_WORKFLOW"
grep -q 'pretag-router-ui-candidate-' "$CANDIDATE_WORKFLOW"
grep -q "network.lan.proto='dhcp'" "$VM_GATE"
grep -q 'HOST_ORIGIN="https://127.0.0.1:' "$VM_GATE"
grep -q 'host_bin/sha256' "$VM_GATE"
grep -q 'VM base build failed' "$VM_GATE"
grep -q 'umask 022.*make -C.*image' "$VM_GATE"
grep -q 'extract_openwrt_gzip_image' "$VM_GATE"
grep -q 'decompression OK, trailing garbage ignored' "$VM_GATE"
grep -q "awk 'NF { count++ } END { print count + 0 }'" "$VM_GATE"
grep -q 'qemu-img info --output=json' "$VM_GATE"
grep -q '/proc/mounts' "$VM_GUEST"

# The overlay may contain only the root redirect and the signed exact-package
# recovery set. Project application paths remain owned by the canonical IPKs.
overlay_section="$(sed -n '/^rm -rf "$OVERLAY"/,/^PACKAGES=/p' "$BUILDER")"
printf '%s\n' "$overlay_section" | grep -q 'www/index.html'
printf '%s\n' "$overlay_section" | grep -q 'installed-manifest.json'
printf '%s\n' "$overlay_section" | grep -q 'known-good'
! printf '%s\n' "$overlay_section" | grep -Eq 'luci-static|usr/sbin/vpn-ui|usr/share/vpn-ui'

printf 'Image pipeline consumes canonical IPKs and records package identity\n'
