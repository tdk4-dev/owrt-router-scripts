#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vpn-ui-publisher-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
FIXTURE_ROOT="$TMP_ROOT/repo"
RELEASE_DIR="$TMP_ROOT/release"
PUBLISHED_DIR="$TMP_ROOT/published"
MOCK_BIN="$TMP_ROOT/gh"
LOG_FILE="$TMP_ROOT/gh.log"
mkdir -p "$FIXTURE_ROOT/luci-vpn-ui" "$RELEASE_DIR" "$PUBLISHED_DIR"
printf '0.7.11\n' > "$FIXTURE_ROOT/luci-vpn-ui/VERSION"
printf 'release notes\n' > "$FIXTURE_ROOT/luci-vpn-ui/RELEASE_NOTES.md"
git -C "$FIXTURE_ROOT" init -q
git -C "$FIXTURE_ROOT" config user.name 'Publisher Test'
git -C "$FIXTURE_ROOT" config user.email publisher@example.invalid
git -C "$FIXTURE_ROOT" add luci-vpn-ui
git -C "$FIXTURE_ROOT" commit -qm baseline
commit="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"
git -C "$FIXTURE_ROOT" tag -a vpn-panel-v0.7.11 -m 'Router UI 0.7.11'
git -C "$FIXTURE_ROOT" update-ref refs/remotes/origin/main "$commit"

printf '{"source_commit":"%s"}\n' "$commit" > "$RELEASE_DIR/router-release-manifest.json"
printf 'asset bytes\n' > "$RELEASE_DIR/example.bin"

cat > "$MOCK_BIN" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_GH_LOG"
[ "$1" = release ] || exit 2
case "$2" in
  view)
    [ -f "$MOCK_PUBLISHED_DIR/.exists" ] || exit 1
    case " $* " in
      *' --json '*) printf '{"name":"Router UI 0.7.11","isDraft":true,"tagName":"vpn-panel-v0.7.11","targetCommitish":"main"}\n' ;;
    esac
    ;;
  create)
    cp "$MOCK_RELEASE_DIR"/* "$MOCK_PUBLISHED_DIR/"
    : > "$MOCK_PUBLISHED_DIR/.exists"
    ;;
  download)
    out=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --dir ]; then out="$2"; break; fi
      shift
    done
    [ -n "$out" ]
    find "$MOCK_PUBLISHED_DIR" -maxdepth 1 -type f ! -name .exists -exec cp {} "$out/" \;
    ;;
  edit) ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$MOCK_BIN"

run_publisher() {
  MOCK_GH_LOG="$LOG_FILE" MOCK_RELEASE_DIR="$RELEASE_DIR" \
  MOCK_PUBLISHED_DIR="$PUBLISHED_DIR" GH_BIN="$MOCK_BIN" \
  RELEASE_ROOT_DIR="$FIXTURE_ROOT" RELEASE_DIR="$RELEASE_DIR" \
  VALIDATE_STAGED_RELEASE=0 GITHUB_REF_NAME=vpn-panel-v0.7.11 \
    "$ROOT_DIR/publish-vpn-panel-release.sh"
}

: > "$LOG_FILE"
run_publisher | grep -q 'publication remains gated'
grep -q '^release create vpn-panel-v0.7.11 ' "$LOG_FILE"
grep -q -- '--draft --verify-tag' "$LOG_FILE"
! grep -q '^release edit ' "$LOG_FILE"

: > "$LOG_FILE"
run_publisher >/dev/null
grep -q '^release download vpn-panel-v0.7.11 ' "$LOG_FILE"
! grep -q '^release create ' "$LOG_FILE"

printf 'different bytes\n' > "$PUBLISHED_DIR/example.bin"
: > "$LOG_FILE"
if run_publisher > "$TMP_ROOT/mismatch.out" 2> "$TMP_ROOT/mismatch.err"; then
  printf 'publisher accepted mismatched existing bytes\n' >&2
  exit 1
fi
grep -q 'draft asset differs: example.bin' "$TMP_ROOT/mismatch.err"
! grep -q '^release edit ' "$LOG_FILE"

cp "$RELEASE_DIR/example.bin" "$PUBLISHED_DIR/example.bin"
: > "$LOG_FILE"
PUBLISH_VERIFIED_RELEASE=1 run_publisher | grep -q 'Published verified release'
grep -q '^release edit vpn-panel-v0.7.11 --draft=false --latest' "$LOG_FILE"

git -C "$FIXTURE_ROOT" tag -d vpn-panel-v0.7.11 >/dev/null
git -C "$FIXTURE_ROOT" tag vpn-panel-v0.7.11
if run_publisher > "$TMP_ROOT/lightweight.out" 2> "$TMP_ROOT/lightweight.err"; then
  printf 'publisher accepted a lightweight tag\n' >&2
  exit 1
fi
grep -q 'existing annotated tag is required' "$TMP_ROOT/lightweight.err"

printf 'Draft-first release publisher checks passed\n'
