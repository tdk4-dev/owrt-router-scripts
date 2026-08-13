#!/bin/sh
set -eu
umask 077

UCODE_COMMIT=3f64c8089bf3ea4847c96b91df09fbfcaec19e1d
UCODE_SOURCE_URL="${UCODE_SOURCE_URL:-https://github.com/jow-/ucode.git}"
UCODE_INSTALL_DIR="${UCODE_INSTALL_DIR:?UCODE_INSTALL_DIR is required}"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/router-ucode-build.XXXXXX")"
RUNTIME="$UCODE_INSTALL_DIR/ucode-runtime"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in cmake git install; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

if [ "$(uname -s)" = Darwin ]; then
  CFLAGS="${CFLAGS:-} -Wno-error=unguarded-availability-new"
  export CFLAGS
fi

git clone --quiet "$UCODE_SOURCE_URL" "$WORK/source"
git -C "$WORK/source" -c advice.detachedHead=false checkout --quiet --detach "$UCODE_COMMIT"
[ "$(git -C "$WORK/source" rev-parse HEAD)" = "$UCODE_COMMIT" ] ||
  fail 'checked-out ucode commit does not match the pinned source'

cmake -S "$WORK/source" -B "$WORK/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$RUNTIME" \
  -DDEBUG_SUPPORT=OFF \
  -DDIGEST_SUPPORT=OFF \
  -DLOG_SUPPORT=OFF \
  -DMATH_SUPPORT=OFF \
  -DNL80211_SUPPORT=OFF \
  -DRESOLV_SUPPORT=OFF \
  -DRTNL_SUPPORT=OFF \
  -DSOCKET_SUPPORT=OFF \
  -DSTRUCT_SUPPORT=OFF \
  -DUBUS_SUPPORT=OFF \
  -DUCI_SUPPORT=OFF \
  -DULOOP_SUPPORT=OFF \
  -DZLIB_SUPPORT=OFF >/dev/null
cmake --build "$WORK/build" --parallel 2 >/dev/null
mkdir -p "$UCODE_INSTALL_DIR"
cmake --install "$WORK/build" >/dev/null

cat > "$UCODE_INSTALL_DIR/ucode" <<EOF
#!/bin/sh
UCODE_CI_RUNTIME='$RUNTIME'
export LD_LIBRARY_PATH="\$UCODE_CI_RUNTIME/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export DYLD_LIBRARY_PATH="\$UCODE_CI_RUNTIME/lib\${DYLD_LIBRARY_PATH:+:\$DYLD_LIBRARY_PATH}"
exec "\$UCODE_CI_RUNTIME/bin/ucode" "\$@"
EOF
chmod 0755 "$UCODE_INSTALL_DIR/ucode"

[ "$("$UCODE_INSTALL_DIR/ucode" -e \
  'import { readfile } from "fs"; print(type(readfile));')" = function ] ||
  fail 'built ucode binary failed its filesystem-module smoke test'

printf 'Installed pinned OpenWrt ucode %s at %s\n' \
  "$UCODE_COMMIT" "$UCODE_INSTALL_DIR/ucode"
