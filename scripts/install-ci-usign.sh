#!/bin/sh
set -eu
umask 077

USIGN_COMMIT=c4c72b1b07945ee192361dc751291a7c98d6adcd
USIGN_SOURCE_URL="${USIGN_SOURCE_URL:-https://git.openwrt.org/project/usign.git}"
USIGN_INSTALL_DIR="${USIGN_INSTALL_DIR:?USIGN_INSTALL_DIR is required}"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/router-usign-build.XXXXXX")"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in cmake git install; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

git clone --quiet "$USIGN_SOURCE_URL" "$WORK/source"
git -C "$WORK/source" -c advice.detachedHead=false checkout --quiet --detach "$USIGN_COMMIT"
[ "$(git -C "$WORK/source" rev-parse HEAD)" = "$USIGN_COMMIT" ] ||
  fail 'checked-out usign commit does not match the pinned source'

cmake -S "$WORK/source" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$WORK/build" --parallel 2 >/dev/null
mkdir -p "$USIGN_INSTALL_DIR"
install -m 0755 "$WORK/build/usign" "$USIGN_INSTALL_DIR/usign"
"$USIGN_INSTALL_DIR/usign" 2>&1 | grep -q '^Usage: .*usign ' ||
  fail 'built usign binary failed its usage smoke test'

printf 'Installed pinned OpenWrt usign %s at %s\n' \
  "$USIGN_COMMIT" "$USIGN_INSTALL_DIR/usign"
