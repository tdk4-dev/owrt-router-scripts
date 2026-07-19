#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vpn-ui-publisher-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

FIXTURE_ROOT="$TMP_ROOT/repo"
MOCK_BIN="$TMP_ROOT/mock-gh"
PUBLISHED_DIR="$TMP_ROOT/published"
LOG_FILE="$TMP_ROOT/gh.log"

mkdir -p "$FIXTURE_ROOT/luci-vpn-ui" "$FIXTURE_ROOT/dist" "$PUBLISHED_DIR"
printf '0.7.10\n' > "$FIXTURE_ROOT/luci-vpn-ui/VERSION"
printf 'release notes\n' > "$FIXTURE_ROOT/luci-vpn-ui/RELEASE_NOTES.md"

for name in \
  luci-vpn-ui.tar.gz \
  luci-vpn-ui.tar.gz.sha256 \
  vpn-ui-version.txt \
  vpn-ui-changelog.txt \
  vpn-ui-release-date.txt \
  install-router-ui-release.sh \
  install-router-ui-release.sh.sha256
do
  printf 'fixture %s\n' "$name" > "$FIXTURE_ROOT/dist/$name"
done

cat > "$MOCK_BIN" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_GH_LOG"

[ "$1" = "release" ] || exit 2
case "$2:$MOCK_GH_MODE" in
  view:create)
    exit 1
    ;;
  view:existing|view:mismatch)
    if [ "${4:-}" = "--json" ]; then
      printf 'Router UI 0.7.10\n'
    fi
    ;;
  create:create)
    ;;
  download:existing|download:mismatch)
    shift 2
    tag="$1"
    shift
    [ "$tag" = "vpn-panel-v0.7.10" ]
    [ "$1" = "--dir" ]
    cp "$MOCK_PUBLISHED_DIR"/* "$2"/
    ;;
  *)
    printf 'unexpected mock gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod 755 "$MOCK_BIN"

: > "$LOG_FILE"
MOCK_GH_MODE=create \
MOCK_GH_LOG="$LOG_FILE" \
MOCK_PUBLISHED_DIR="$PUBLISHED_DIR" \
GH_BIN="$MOCK_BIN" \
RELEASE_ROOT_DIR="$FIXTURE_ROOT" \
GITHUB_REF_NAME=vpn-panel-v0.7.10 \
  "$ROOT_DIR/publish-vpn-panel-release.sh"
grep -q '^release create vpn-panel-v0.7.10 ' "$LOG_FILE"
! grep -q '^release upload ' "$LOG_FILE"

cp "$FIXTURE_ROOT/dist/"* "$PUBLISHED_DIR/"
: > "$LOG_FILE"
MOCK_GH_MODE=existing \
MOCK_GH_LOG="$LOG_FILE" \
MOCK_PUBLISHED_DIR="$PUBLISHED_DIR" \
GH_BIN="$MOCK_BIN" \
RELEASE_ROOT_DIR="$FIXTURE_ROOT" \
GITHUB_REF_NAME=vpn-panel-v0.7.10 \
  "$ROOT_DIR/publish-vpn-panel-release.sh"
grep -q '^release download vpn-panel-v0.7.10 ' "$LOG_FILE"
! grep -Eq '^release (create|upload|edit) ' "$LOG_FILE"

printf 'different\n' > "$PUBLISHED_DIR/vpn-ui-version.txt"
: > "$LOG_FILE"
if MOCK_GH_MODE=mismatch \
  MOCK_GH_LOG="$LOG_FILE" \
  MOCK_PUBLISHED_DIR="$PUBLISHED_DIR" \
  GH_BIN="$MOCK_BIN" \
  RELEASE_ROOT_DIR="$FIXTURE_ROOT" \
  GITHUB_REF_NAME=vpn-panel-v0.7.10 \
    "$ROOT_DIR/publish-vpn-panel-release.sh"
then
  printf 'publisher accepted a mismatched existing asset\n' >&2
  exit 1
fi
! grep -Eq '^release (create|upload|edit) ' "$LOG_FILE"

printf 'Release publisher checks passed\n'
