#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RESCUE="$ROOT_DIR/rescue-router-ui-0.7.1.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-071-rescue-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

BIN_DIR="$TMP_ROOT/bin"
FIXTURE_DIR="$TMP_ROOT/fixtures"
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$BIN_DIR" "$FIXTURE_DIR/latest" "$FIXTURE_DIR/0.7.9" \
  "$FIXTURE_DIR/0.7.10" "$STATE_DIR"

cat > "$BIN_DIR/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-u" ] || exit 2
printf '0\n'
EOF

cat > "$BIN_DIR/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$BIN_DIR/curl" <<'EOF'
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
[ -n "$dst" ] && [ -n "$url" ]
printf '%s\n' "$url" >> "${RESCUE_FETCH_LOG:?}"
case "$url" in
  */releases/latest/download/vpn-ui-version.txt)
    src="${RESCUE_FIXTURES:?}/latest/vpn-ui-version.txt"
    ;;
  */releases/download/vpn-panel-v0.7.9/*)
    src="${RESCUE_FIXTURES:?}/0.7.9/${url##*/}"
    ;;
  */releases/download/vpn-panel-v0.7.10/*)
    src="${RESCUE_FIXTURES:?}/0.7.10/${url##*/}"
    ;;
  *) exit 22 ;;
esac
[ -f "$src" ] || exit 22
cp "$src" "$dst"
EOF
chmod 755 "$BIN_DIR/id" "$BIN_DIR/sleep" "$BIN_DIR/curl"

make_release() {
  version="$1"
  release_dir="$FIXTURE_DIR/$version"
  printf '%s\n' "$version" > "$release_dir/vpn-ui-version.txt"
  if [ "$version" = "0.7.9" ]; then
    cat > "$release_dir/install-router-ui-release.sh" <<'EOF'
#!/bin/sh
set -eu
validate_legacy_update_route() {
  sed -n 's/.*"path":[[:space:]]*"\(system\/update-[^"]*\)".*/\1/p' /dev/null
}
grep -Fq '\(system\/update\(-[^"]*\)\{0,1\}\)' "$0"
printf '%s\n' "${ROUTER_UI_VERSION:?}" > "${ROUTER_UI_VERSION_FILE:?}"
printf '%s %s\n' "$ROUTER_UI_VERSION" "${ROUTER_UI_REPO:?}" >> "${RESCUE_INSTALL_LOG:?}"
EOF
  else
    cat > "$release_dir/install-router-ui-release.sh" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "${ROUTER_UI_VERSION:?}" > "${ROUTER_UI_VERSION_FILE:?}"
printf '%s %s\n' "$ROUTER_UI_VERSION" "${ROUTER_UI_REPO:?}" >> "${RESCUE_INSTALL_LOG:?}"
EOF
  fi
  chmod 755 "$release_dir/install-router-ui-release.sh"
  (
    cd "$release_dir"
    sha256sum install-router-ui-release.sh > install-router-ui-release.sh.sha256
  )
}

make_release 0.7.9
make_release 0.7.10
printf '0.7.9\n' > "$FIXTURE_DIR/latest/vpn-ui-version.txt"
printf 'DISTRIB_ID=OpenWrt\n' > "$STATE_DIR/openwrt_release"
: > "$STATE_DIR/fetch.log"
: > "$STATE_DIR/install.log"
unset ROUTER_UI_VERSION

run_rescue() {
  PATH="$BIN_DIR:$PATH" \
  RESCUE_FIXTURES="$FIXTURE_DIR" \
  RESCUE_FETCH_LOG="$STATE_DIR/fetch.log" \
  RESCUE_INSTALL_LOG="$STATE_DIR/install.log" \
  ROUTER_UI_OPENWRT_RELEASE_FILE="$STATE_DIR/openwrt_release" \
  ROUTER_UI_VERSION_FILE="$STATE_DIR/version" \
    sh "$RESCUE" "$@"
}

printf '0.7.1\n' > "$STATE_DIR/version"
run_rescue >/dev/null
[ "$(cat "$STATE_DIR/version")" = "0.7.9" ]
grep -q '/releases/latest/download/vpn-ui-version.txt$' "$STATE_DIR/fetch.log"
grep -q '/releases/download/vpn-panel-v0.7.9/install-router-ui-release.sh$' \
  "$STATE_DIR/fetch.log"
grep -q '^0.7.9 tdk4-dev/owrt-router-scripts$' "$STATE_DIR/install.log"

before_installs="$(wc -l < "$STATE_DIR/install.log" | tr -d ' ')"
ROUTER_UI_VERSION=0.7.9 run_rescue >/dev/null
after_installs="$(wc -l < "$STATE_DIR/install.log" | tr -d ' ')"
[ "$before_installs" = "$after_installs" ]

printf '0.7.9\n' > "$STATE_DIR/version"
ROUTER_UI_VERSION=0.7.10 run_rescue >/dev/null
[ "$(cat "$STATE_DIR/version")" = "0.7.10" ]
grep -q '/releases/download/vpn-panel-v0.7.10/install-router-ui-release.sh$' \
  "$STATE_DIR/fetch.log"

printf '0.7.10\n' > "$STATE_DIR/version"
if ROUTER_UI_VERSION=0.7.9 run_rescue >/dev/null 2>&1; then
  printf 'rescue accepted a downgrade from 0.7.10 to 0.7.9\n' >&2
  exit 1
fi

printf '0.7.5\n' > "$STATE_DIR/version"
if ROUTER_UI_VERSION=0.7.9 run_rescue >/dev/null 2>&1; then
  printf 'rescue accepted an out-of-scope installed version\n' >&2
  exit 1
fi

printf '0.7.1\n' > "$STATE_DIR/version"
printf '0.8.0\n' > "$FIXTURE_DIR/latest/vpn-ui-version.txt"
unset ROUTER_UI_VERSION
if run_rescue >/dev/null 2>&1; then
  printf 'rescue accepted an out-of-scope latest version\n' >&2
  exit 1
fi
printf '0.7.9\n' > "$FIXTURE_DIR/latest/vpn-ui-version.txt"

printf '%064d  install-router-ui-release.sh\n' 0 > \
  "$FIXTURE_DIR/0.7.9/install-router-ui-release.sh.sha256"
if ROUTER_UI_VERSION=0.7.9 run_rescue >/dev/null 2>&1; then
  printf 'rescue accepted a mismatched installer checksum\n' >&2
  exit 1
fi

printf 'Router UI 0.7.1 updater rescue checks passed\n'
