#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UPDATER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/update-compat-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/release" "$TMP_DIR/cache" "$TMP_DIR/state"
printf '%s\n' 0.8.0 > "$TMP_DIR/current-version"
printf '%s\n' 0.7.9 > "$TMP_DIR/release/vpn-ui-version.txt"
printf '%s\n' 'Legacy release notes' > "$TMP_DIR/release/vpn-ui-changelog.txt"
printf '%s\n' '2026-07-01' > "$TMP_DIR/release/vpn-ui-release-date.txt"

cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/bin/sh
set -eu
dst=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) dst="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
src="${FAKE_RELEASE_DIR:?}/${url##*/}"
[ -f "$src" ] || exit 22
cp "$src" "$dst"
EOF
cat > "$TMP_DIR/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$TMP_DIR/bin/curl" "$TMP_DIR/bin/sleep"

run_update() {
  PATH="$TMP_DIR/bin:$PATH" \
  FAKE_RELEASE_DIR="$TMP_DIR/release" \
  VPN_UI_RELEASE_BASE='https://release.example.test/latest/download' \
  VPN_UI_VERSION_FILE="$TMP_DIR/current-version" \
  VPN_UI_UPDATE_CONFIG="$TMP_DIR/config" \
  VPN_UI_UPDATE_CACHE="$TMP_DIR/cache" \
  VPN_UI_UPDATE_STATE="$TMP_DIR/state" \
  VPN_UI_UPDATE_LOCK="$TMP_DIR/lock" \
  VPN_UI_UPDATE_LOG="$TMP_DIR/update.log" \
  VPN_UI_UPDATE_RESTART_CRON=0 \
    sh "$UPDATER" "$@"
}

run_update check-worker
legacy_status="$(run_update status)"
printf '%s\n' "$legacy_status" | grep -q '"compatible_release":false'
printf '%s\n' "$legacy_status" | grep -q '"release_reachable":true'
printf '%s\n' "$legacy_status" | grep -q '"current_ahead":true'
printf '%s\n' "$legacy_status" | grep -q '"status":"success"'
printf '%s\n' "$legacy_status" | grep -q 'published legacy-format release'
if printf '%s\n' "$legacy_status" | grep -q 'Could not contact'; then
  printf 'legacy release was misreported as a connectivity failure\n' >&2
  exit 1
fi

printf '%s\n' 0.8.1 > "$TMP_DIR/release/vpn-ui-version.txt"
printf '%s\n' '{}' > "$TMP_DIR/release/router-release-manifest.json"
printf '%s\n' 'premier-router-core_0.8.1-1_all.ipk' > "$TMP_DIR/release/router-ui-packages.txt"
rm -rf "$TMP_DIR/cache" "$TMP_DIR/state"
mkdir -p "$TMP_DIR/cache" "$TMP_DIR/state"
run_update check-worker
package_status="$(run_update status)"
printf '%s\n' "$package_status" | grep -q '"compatible_release":true'
printf '%s\n' "$package_status" | grep -q '"available":true'
printf '%s\n' "$package_status" | grep -q '"latest":"0.8.1"'

printf '%s\n' 'Updater legacy/package-first compatibility checks passed'
