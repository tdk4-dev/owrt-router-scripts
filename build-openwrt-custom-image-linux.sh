#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
TARGET_DIR="${TARGET_DIR:-x86/64}"
PROFILE="${PROFILE:-generic}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-512}"
WRITABLE_BUDGET_KIB="${WRITABLE_BUDGET_KIB:-0}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.imagebuilder}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
if [ -n "${PACKAGE_FILE:-}" ]; then
  PACKAGE_FILE="$PACKAGE_FILE"
elif [ "$TARGET_DIR" = "mediatek/filogic" ]; then
  PACKAGE_FILE="$ROOT_DIR/image/openwrt-rd23-packages.txt"
else
  PACKAGE_FILE="$ROOT_DIR/image/openwrt-fin0-packages.txt"
fi
PROJECT_PACKAGE_DIR="${PROJECT_PACKAGE_DIR:-$ROOT_DIR/dist/ipk}"
PROJECT_PACKAGE_MANIFEST="${PROJECT_PACKAGE_MANIFEST:-$PROJECT_PACKAGE_DIR/router-ui-packages.txt}"
INSTALLED_PACKAGE_SET_DIR="${INSTALLED_PACKAGE_SET_DIR:?INSTALLED_PACKAGE_SET_DIR is required}"
PROJECT_FEED_DIR="${PROJECT_FEED_DIR:-$ROOT_DIR/dist/opkg-feed}"
PROJECT_PACKAGES="${PROJECT_PACKAGES:-premier-router-core luci-app-premier-router premier-router-setup}"
PKG_VERSION="$APP_VERSION-1"
SOURCE_COMMIT="${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
SOURCE_DIRTY="${SOURCE_DIRTY:-false}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" show -s --format=%ct "$SOURCE_COMMIT")}"
IB_TARGET_NAME="$(printf '%s' "$TARGET_DIR" | tr '/' '-')"
if [ "$TARGET_DIR" = "x86/64" ] && [ "$PROFILE" = "generic" ]; then
  DEFAULT_ARTIFACT_PREFIX="premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-x86-64"
else
  DEFAULT_ARTIFACT_PREFIX="premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-${TARGET_DIR%/*}-${TARGET_DIR#*/}-$PROFILE"
fi
ARTIFACT_PREFIX="${ARTIFACT_PREFIX:-$DEFAULT_ARTIFACT_PREFIX}"
IB_NAME="openwrt-imagebuilder-$OPENWRT_VERSION-$IB_TARGET_NAME.Linux-x86_64"
IB_ARCHIVE="$IB_NAME.tar.zst"
IB_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/$TARGET_DIR/$IB_ARCHIVE"
IB_DIR="$WORK_DIR/$IB_NAME"
OVERLAY="$WORK_DIR/overlay-$IB_TARGET_NAME-$PROFILE"
PROFILE_INFO="$WORK_DIR/profile-info-$IB_TARGET_NAME-$PROFILE.txt"
BUILD_LOG="$OUT_DIR/$ARTIFACT_PREFIX.build.log"
HOST_TOOLS_ROOT="${HOST_TOOLS_ROOT:-$ROOT_DIR/.host-tools/root}"

if [ -x "$HOST_TOOLS_ROOT/usr/bin/gawk" ]; then
  mkdir -p "$HOST_TOOLS_ROOT/bin"
  ln -sf ../usr/bin/gawk "$HOST_TOOLS_ROOT/bin/awk"
  PATH="$HOST_TOOLS_ROOT/bin:$HOST_TOOLS_ROOT/usr/bin:$PATH"
  LD_LIBRARY_PATH="$HOST_TOOLS_ROOT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  AWKPATH="$HOST_TOOLS_ROOT/usr/share/awk${AWKPATH:+:$AWKPATH}"
  AWKLIBPATH="$HOST_TOOLS_ROOT/usr/lib/x86_64-linux-gnu/gawk${AWKLIBPATH:+:$AWKLIBPATH}"
  export PATH LD_LIBRARY_PATH AWKPATH AWKLIBPATH
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for tool in curl tar zstd make sha256sum awk find sort tee; do
  need "$tool"
done

HOST_BIN="$WORK_DIR/host-bin"
mkdir -p "$HOST_BIN"
cat > "$HOST_BIN/sha256" <<'EOF'
#!/bin/sh
sha256sum "$@" | awk '{ print $1 }'
EOF
chmod 755 "$HOST_BIN/sha256"
PATH="$HOST_BIN:$PATH"
export PATH

[ -f "$PACKAGE_FILE" ] || {
  printf 'Missing package file: %s\n' "$PACKAGE_FILE" >&2
  exit 1
}

mkdir -p "$WORK_DIR" "$OUT_DIR"

for pkg in $PROJECT_PACKAGES; do
  ls "$PROJECT_PACKAGE_DIR/${pkg}_"*.ipk >/dev/null 2>&1 || {
    printf 'Missing prebuilt project package for %s in %s\n' "$pkg" "$PROJECT_PACKAGE_DIR" >&2
    printf 'Run ./scripts/build-openwrt-ipks.sh before building images.\n' >&2
    exit 1
  }
done
[ -f "$PROJECT_PACKAGE_MANIFEST" ] || {
  printf 'Missing project package manifest: %s\n' "$PROJECT_PACKAGE_MANIFEST" >&2
  exit 1
}
while read -r pkg version architecture sha size filename; do
  [ -n "${pkg:-}" ] || continue
  [ "$version" = "$PKG_VERSION" ] && [ "$architecture" = all ] ||
    { printf 'Canonical package manifest version mismatch: %s\n' "$pkg" >&2; exit 1; }
  file="$PROJECT_PACKAGE_DIR/$filename"
  [ -f "$file" ] &&
    [ "$(sha256sum "$file" | awk '{print $1}')" = "$sha" ] &&
    [ "$(wc -c < "$file" | tr -d ' ')" = "$size" ] ||
    { printf 'Canonical package manifest hash/size mismatch: %s\n' "$pkg" >&2; exit 1; }
done < "$PROJECT_PACKAGE_MANIFEST"

if [ ! -d "$IB_DIR" ]; then
  if [ ! -f "$WORK_DIR/$IB_ARCHIVE" ]; then
    printf 'Downloading ImageBuilder %s for %s...\n' "$OPENWRT_VERSION" "$TARGET_DIR"
    curl -fL --connect-timeout 15 --max-time 600 "$IB_URL" -o "$WORK_DIR/$IB_ARCHIVE"
  else
    printf 'Using preloaded ImageBuilder archive: %s\n' "$WORK_DIR/$IB_ARCHIVE"
  fi
  tar --use-compress-program=unzstd -xf "$WORK_DIR/$IB_ARCHIVE" -C "$WORK_DIR"
fi

make -s -C "$IB_DIR" info > "$PROFILE_INFO"
awk -v profile="$PROFILE" '$0 == profile ":" { found=1 } END { exit !found }' "$PROFILE_INFO" || {
  printf 'Profile %s is not present in the OpenWrt %s %s ImageBuilder\n' \
    "$PROFILE" "$OPENWRT_VERSION" "$TARGET_DIR" >&2
  exit 1
}

install_project_feed() {
  local pkg_dir="$IB_DIR/packages"
  local pkg
  mkdir -p "$pkg_dir"
  for pkg in $PROJECT_PACKAGES; do
    rm -f "$pkg_dir/${pkg}_"*.ipk
  done
  for pkg in $PROJECT_PACKAGES; do
    file="$PROJECT_PACKAGE_DIR/${pkg}_${PKG_VERSION}_all.ipk"
    [ -f "$file" ] || {
      printf 'Missing exact canonical package: %s\n' "$file" >&2
      exit 1
    }
    cp "$file" "$pkg_dir/"
  done
  stale_count="$(find "$pkg_dir" -maxdepth 1 -type f \
    \( -name 'premier-router-core_*.ipk' -o -name 'luci-app-premier-router_*.ipk' \
       -o -name 'premier-router-setup_*.ipk' \) | wc -l | tr -d ' ')"
  [ "$stale_count" = 3 ] || {
    printf 'ImageBuilder contains stale project IPKs\n' >&2
    exit 1
  }
  # Let `make image` generate its ephemeral local build key and sign this exact
  # feed. Pre-generating Packages here races _check_keys and leaves an unsigned
  # index that opkg correctly refuses.
  rm -f "$pkg_dir/Packages" "$pkg_dir/Packages.gz" "$pkg_dir/Packages.sig"
}

install_project_feed

rm -rf "$OVERLAY"
mkdir -p "$OVERLAY/www"
copy_root_redirect="$ROOT_DIR/image-overlay/www/index.html"
if [ -f "$copy_root_redirect" ]; then
  cp "$copy_root_redirect" "$OVERLAY/www/index.html"
  chmod 644 "$OVERLAY/www/index.html"
fi

(cd "$INSTALLED_PACKAGE_SET_DIR" && sha256sum -c SHA256SUMS >/dev/null) || {
  printf 'Signed installed package-set checksums failed\n' >&2
  exit 1
}
cmp -s "$INSTALLED_PACKAGE_SET_DIR/release.pub" "$ROOT_DIR/release/keys/router-ui-production.pub" || {
  printf 'Installed package set uses another public key\n' >&2
  exit 1
}
PACKAGE_SET_HASH="$(sha256sum "$INSTALLED_PACKAGE_SET_DIR/installed-manifest.json" | awk '{print $1}')"
mkdir -p "$OVERLAY/etc/premier-router" \
  "$OVERLAY/root/premier-router-updates/known-good/$PACKAGE_SET_HASH"
cp "$INSTALLED_PACKAGE_SET_DIR/installed-manifest.json" \
  "$OVERLAY/etc/premier-router/installed-manifest.json"
cp "$INSTALLED_PACKAGE_SET_DIR/installed-manifest.json.sig" \
  "$OVERLAY/etc/premier-router/installed-manifest.json.sig"
for file in "$INSTALLED_PACKAGE_SET_DIR"/*.ipk; do
  cp "$file" "$OVERLAY/root/premier-router-updates/known-good/$PACKAGE_SET_HASH/"
done
cp "$INSTALLED_PACKAGE_SET_DIR/router-candidate-validator" \
  "$OVERLAY/root/premier-router-updates/known-good/$PACKAGE_SET_HASH/router-candidate-validator"
cp "$INSTALLED_PACKAGE_SET_DIR/installed-manifest.json" \
  "$OVERLAY/root/premier-router-updates/known-good/$PACKAGE_SET_HASH/router-release-manifest.json"
cp "$INSTALLED_PACKAGE_SET_DIR/installed-manifest.json.sig" \
  "$OVERLAY/root/premier-router-updates/known-good/$PACKAGE_SET_HASH/router-release-manifest.json.sig"

PACKAGES="$(awk 'NF && $1 !~ /^#/ { printf "%s ", $1 }' "$PACKAGE_FILE") $PROJECT_PACKAGES"
TARGET_OUT="$IB_DIR/bin/targets/$TARGET_DIR"

# ImageBuilder keeps prior profile outputs in bin/targets. Start each artifact
# assembly from one profile so cached stock and ubootmod files cannot leak into
# each other's archive or checksum manifest.
rm -rf "$TARGET_OUT"

printf 'Building OpenWrt %s %s profile %s...\n' "$OPENWRT_VERSION" "$TARGET_DIR" "$PROFILE"
if [ "$TARGET_DIR" = "x86/64" ]; then
  make -C "$IB_DIR" image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES" \
    FILES="$OVERLAY" \
    ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" > "$BUILD_LOG" 2>&1 || {
      cat "$BUILD_LOG"
      exit 1
    }
else
  make -C "$IB_DIR" image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES" \
    FILES="$OVERLAY" > "$BUILD_LOG" 2>&1 || {
      cat "$BUILD_LOG"
      exit 1
    }
fi
cat "$BUILD_LOG"

MANIFEST_SRC="$(find "$TARGET_OUT" -maxdepth 1 -type f -name '*.manifest' | sort | tail -n 1)"
[ -n "$MANIFEST_SRC" ] || {
  printf 'ImageBuilder did not produce a package manifest\n' >&2
  exit 1
}
for pkg in $PROJECT_PACKAGES; do
  grep -q "^$pkg - $PKG_VERSION$" "$MANIFEST_SRC" || {
    printf 'Built image manifest is missing %s %s\n' "$pkg" "$PKG_VERSION" >&2
    exit 1
  }
done

BUILT_ROOT=""
for candidate_root in "$IB_DIR"/build_dir/target-*/root-*; do
  [ -d "$candidate_root" ] || continue
  if [ -f "$candidate_root/usr/share/vpn-ui/version" ] &&
    [ "$(sed -n '1p' "$candidate_root/usr/share/vpn-ui/version")" = "$APP_VERSION" ]; then
    BUILT_ROOT="$candidate_root"
    break
  fi
done
[ -n "$BUILT_ROOT" ] || {
  printf 'Could not locate the exact ImageBuilder root used for the image\n' >&2
  exit 1
}

PAYLOAD_WORK="$(mktemp -d "${TMPDIR:-/tmp}/router-image-payload.XXXXXX")"
PAYLOAD_PROOF="$PAYLOAD_WORK/project-payload-sha256sums"
: > "$PAYLOAD_PROOF"
for pkg in $PROJECT_PACKAGES; do
  pkg_root="$PAYLOAD_WORK/$pkg"
  mkdir -p "$pkg_root"
  tar -xzOf "$PROJECT_PACKAGE_DIR/${pkg}_${PKG_VERSION}_all.ipk" ./data.tar.gz |
    tar -xzf - -C "$pkg_root"
  find "$pkg_root" \( -type f -o -type l \) -print | LC_ALL=C sort |
    while IFS= read -r source_file; do
      rel="${source_file#$pkg_root/}"
      built_file="$BUILT_ROOT/$rel"
      [ -e "$built_file" ] || [ -L "$built_file" ] || {
        printf 'Image root omitted package payload: %s %s\n' "$pkg" "$rel" >&2
        exit 1
      }
      if [ -L "$source_file" ]; then
        [ -L "$built_file" ] && [ "$(readlink "$source_file")" = "$(readlink "$built_file")" ] || exit 1
        payload_sha="$(printf '%s' "$(readlink "$source_file")" | sha256sum | awk '{print $1}')"
        payload_type=link
      else
        cmp -s "$source_file" "$built_file" || {
          printf 'Image root package payload drift: %s %s\n' "$pkg" "$rel" >&2
          exit 1
        }
        payload_sha="$(sha256sum "$source_file" | awk '{print $1}')"
        payload_type=file
      fi
      printf '%s %s %s %s\n' "$pkg" "$payload_type" "$payload_sha" "/$rel" >> "$PAYLOAD_PROOF"
    done
done
LC_ALL=C sort -u "$PAYLOAD_PROOF" -o "$PAYLOAD_PROOF"
PROFILE_ARTIFACT_DIR="$OUT_DIR/$ARTIFACT_PREFIX"
ARCHIVE="$OUT_DIR/$ARTIFACT_PREFIX.tar.gz"

rm -rf "$PROFILE_ARTIFACT_DIR"
mkdir -p "$PROFILE_ARTIFACT_DIR"
find "$TARGET_OUT" -maxdepth 1 -type f \
  \( -name "*$PROFILE*" -o -name 'profiles.json' \) \
  -exec cp {} "$PROFILE_ARTIFACT_DIR/" \;
[ -n "$MANIFEST_SRC" ] && cp "$MANIFEST_SRC" "$PROFILE_ARTIFACT_DIR/" || true
cp "$PACKAGE_FILE" "$PROFILE_ARTIFACT_DIR/packages.txt"
cp "$PROFILE_INFO" "$PROFILE_ARTIFACT_DIR/profile-info.txt"
cp "$PROJECT_PACKAGE_MANIFEST" "$PROFILE_ARTIFACT_DIR/router-ui-packages.txt"
cp "$PAYLOAD_PROOF" "$PROFILE_ARTIFACT_DIR/project-payload-sha256sums"
find "$OVERLAY" \( -type f -o -type l \) -print | sed "s#^$OVERLAY/##" |
  LC_ALL=C sort > "$PROFILE_ARTIFACT_DIR/overlay-files.txt"
(
  cd "$PROJECT_PACKAGE_DIR"
  sha256sum ./*.ipk | sed 's#  \./#  #'
) > "$PROFILE_ARTIFACT_DIR/project-ipk-sha256sums"
cp "$BUILD_LOG" "$PROFILE_ARTIFACT_DIR/build.log"
rm -rf "$PAYLOAD_WORK"
cat > "$PROFILE_ARTIFACT_DIR/image-provenance.json" <<EOF
{
  "schema_version": 1,
  "app_version": "$APP_VERSION",
  "package_version": "$PKG_VERSION",
  "openwrt_version": "$OPENWRT_VERSION",
  "target": "$TARGET_DIR",
  "profile": "$PROFILE",
  "source_commit": "$SOURCE_COMMIT",
  "source_dirty": $SOURCE_DIRTY,
  "source_date_epoch": $SOURCE_DATE_EPOCH,
  "updater_protocol": 2,
  "writable_budget_kib": $WRITABLE_BUDGET_KIB,
  "x86_rootfs_partsize_mib": $ROOTFS_PARTSIZE
}
EOF
(
  cd "$PROFILE_ARTIFACT_DIR"
  find . -maxdepth 1 -type f ! -name sha256sums -print |
    sort |
    sed 's#^\./##' |
    while IFS= read -r artifact; do
      sha256sum "$artifact"
    done > sha256sums
)

if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 \
    --numeric-owner -czf "$ARCHIVE" -C "$OUT_DIR" "$(basename "$PROFILE_ARTIFACT_DIR")"
else
  normalized="$(date -u -r "$SOURCE_DATE_EPOCH" '+%Y%m%d%H%M.%S')"
  find "$PROFILE_ARTIFACT_DIR" -exec env TZ=UTC touch -h -t "$normalized" {} +
  COPYFILE_DISABLE=1 tar --format ustar --no-xattrs --no-mac-metadata \
    --owner=0 --group=0 --numeric-owner -czf "$ARCHIVE" -C "$OUT_DIR" \
    "$(basename "$PROFILE_ARTIFACT_DIR")"
fi
archive_name="$(basename "$ARCHIVE")"
(
  cd "$OUT_DIR"
  sha256sum "$archive_name" > "$archive_name.sha256"
)

printf 'Built artifact archive: %s\n' "$ARCHIVE"
