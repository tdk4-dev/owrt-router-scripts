#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
NORMALIZER="$ROOT_DIR/tests/vm/normalize-listeners.awk"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-listeners.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

cat > "$TMP_ROOT/before" <<'EOF'
Proto Recv-Q Send-Q Local Address Foreign Address State
tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN
tcp 0 0 127.0.0.1:53 0.0.0.0:* LISTEN
tcp 0 0 fe80::aaaa:53 :::* LISTEN
tcp 0 0 fe80::bbbb:53 :::* LISTEN
EOF
cat > "$TMP_ROOT/after" <<'EOF'
Proto Recv-Q Send-Q Local Address Foreign Address State
tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN
tcp 0 0 127.0.0.1:53 0.0.0.0:* LISTEN
tcp 0 0 fe80::aaaa:53 :::* LISTEN
tcp 0 0 fe80::cccc:53 :::* LISTEN
EOF
awk -f "$NORMALIZER" "$TMP_ROOT/before" | LC_ALL=C sort > "$TMP_ROOT/before.normalized"
awk -f "$NORMALIZER" "$TMP_ROOT/after" | LC_ALL=C sort > "$TMP_ROOT/after.normalized"
cmp "$TMP_ROOT/before.normalized" "$TMP_ROOT/after.normalized"

printf '%s\n' 'tcp 0 0 0.0.0.0:8080 0.0.0.0:* LISTEN' >> "$TMP_ROOT/after"
awk -f "$NORMALIZER" "$TMP_ROOT/after" | LC_ALL=C sort > "$TMP_ROOT/after-new-port.normalized"
if cmp -s "$TMP_ROOT/before.normalized" "$TMP_ROOT/after-new-port.normalized"; then
  printf 'listener normalization concealed a new TCP listener\n' >&2
  exit 1
fi

printf 'VM listener normalization contract passed\n'
