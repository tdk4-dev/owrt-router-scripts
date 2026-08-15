#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILDER="$ROOT_DIR/scripts/build-openwrt-ipks.sh"

[ "$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION")" = 0.7.11-rc.15 ]
[ "$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/PACKAGE_VERSION")" = 0.7.11~rc15-1 ]
[ "$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/files/usr/share/vpn-ui/version")" = 0.7.11-rc.15 ]

for source in \
  luci-vpn-ui/files/usr/sbin/vpn-ui \
  luci-vpn-ui/files/usr/sbin/vpn-ui-readonly \
  luci-vpn-ui/files/usr/sbin/vpn-ui-update \
  luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh \
  luci-vpn-ui/files/usr/libexec/premier-router/candidate-validator \
  luci-vpn-ui/files/usr/libexec/premier-router/xray-overlay.uc \
  luci-vpn-ui/files/etc/config/premier_router \
  luci-vpn-ui/files/etc/init.d/premier-router-update-recovery \
  luci-vpn-ui/files/etc/init.d/xray-transparent
do
  test -f "$ROOT_DIR/$source" || {
    printf 'package source is missing: %s\n' "$source" >&2
    exit 1
  }
  grep -Fq "\"\$ROOT_DIR/$source\"" "$BUILDER" || {
    printf 'package builder does not include: %s\n' "$source" >&2
    exit 1
  }
done

grep -Fq '/etc/config/premier_router' "$BUILDER"
grep -Fq 'metadata-init' "$BUILDER"
grep -Fq 'metadata-installed package-first-local-ipk' "$BUILDER"
grep -Fq 'UPDATER_PROTOCOL=$UPDATER_PROTOCOL' "$BUILDER"
grep -Fq 'RELEASE_CHANNEL=$BUILD_CHANNEL' "$BUILDER"
grep -Fq 'coreutils-nohup' "$BUILDER"
grep -Fq 'ucode-mod-fs' "$BUILDER"
grep -Fq 'usign' "$BUILDER"
test -f "$ROOT_DIR/release/router-ui-runtime-ownership.json"
test -f "$ROOT_DIR/release/router-ui-runtime-ownership.md"
jq empty "$ROOT_DIR/release/router-ui-runtime-ownership.json"
sh -n "$ROOT_DIR/tests/vm/router-ui-runtime-census-guest.sh"

for package in premier-router-core luci-app-premier-router premier-router-setup; do
  grep -Fq "\"$package\"" "$BUILDER"
done
[ "$(grep -Ec '^[A-Z_]+_IPK="\$\(create_package ' "$BUILDER")" -eq 3 ]
! grep -Eq '0\.7\.11-rc\.[0-7]|0\.7\.11~rc[0-7]' "$BUILDER"
! grep -Eq 'build_once|reproduc|historical.*build' "$BUILDER"

printf 'Three-IPK source composition, metadata, identity, and single-version contracts passed\n'
