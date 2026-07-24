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
IMAGEBUILDER_LOCAL_KEY_DIR="${IMAGEBUILDER_LOCAL_KEY_DIR:-}"
REQUIRE_PINNED_IMAGEBUILDER_KEY="${REQUIRE_PINNED_IMAGEBUILDER_KEY:-0}"
IMAGEBUILDER_LOCAL_KEY_MODE=generated
IMAGEBUILDER_LOCAL_KEY_FINGERPRINT=
PINNED_IMAGEBUILDER_PRIVATE_KEY=

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

for tool in curl tar zstd make sha256sum awk find sort tee jq stat date; do
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

cleanup_pinned_imagebuilder_private_key() {
  if [ -n "$PINNED_IMAGEBUILDER_PRIVATE_KEY" ]; then
    rm -f "$PINNED_IMAGEBUILDER_PRIVATE_KEY"
  fi
}

if [ -n "$IMAGEBUILDER_LOCAL_KEY_DIR" ]; then
  for key_file in key-build key-build.pub key-build.ucert key-build.ucert.revoke; do
    [ -s "$IMAGEBUILDER_LOCAL_KEY_DIR/$key_file" ] || {
      printf 'Pinned ImageBuilder local key input is missing: %s\n' "$key_file" >&2
      exit 1
    }
  done
  cp "$IMAGEBUILDER_LOCAL_KEY_DIR/key-build" "$IB_DIR/key-build"
  cp "$IMAGEBUILDER_LOCAL_KEY_DIR/key-build.pub" "$IB_DIR/key-build.pub"
  cp "$IMAGEBUILDER_LOCAL_KEY_DIR/key-build.ucert" "$IB_DIR/key-build.ucert"
  cp "$IMAGEBUILDER_LOCAL_KEY_DIR/key-build.ucert.revoke" "$IB_DIR/key-build.ucert.revoke"
  chmod 600 "$IB_DIR/key-build"
  chmod 644 "$IB_DIR/key-build.pub" "$IB_DIR/key-build.ucert" \
    "$IB_DIR/key-build.ucert.revoke"
  IMAGEBUILDER_LOCAL_KEY_FINGERPRINT="$(
    "$IB_DIR/staging_dir/host/bin/usign" -F -p "$IB_DIR/key-build.pub"
  )"
  printf '%s\n' "$IMAGEBUILDER_LOCAL_KEY_FINGERPRINT" |
    grep -Eq '^[0-9a-f]{16}$' || {
      printf 'Could not determine the pinned ImageBuilder local public-key fingerprint\n' >&2
      exit 1
    }
  mkdir -p "$IB_DIR/keys"
  cp "$IB_DIR/key-build.pub" \
    "$IB_DIR/keys/$IMAGEBUILDER_LOCAL_KEY_FINGERPRINT"
  chmod 644 "$IB_DIR/keys/$IMAGEBUILDER_LOCAL_KEY_FINGERPRINT"
  PINNED_IMAGEBUILDER_PRIVATE_KEY="$IB_DIR/key-build"
  trap cleanup_pinned_imagebuilder_private_key EXIT HUP INT TERM
  IMAGEBUILDER_LOCAL_KEY_MODE=locked
elif [ "$REQUIRE_PINNED_IMAGEBUILDER_KEY" = 1 ]; then
  printf 'A pinned ImageBuilder local key directory is required for a reproducible image\n' >&2
  exit 1
fi

if [ "$TARGET_DIR" = "x86/64" ] && [ "$WRITABLE_BUDGET_KIB" -gt 0 ]; then
  if ! grep -q 'ROOTFS_WRITABLE_KIB' "$IB_DIR/scripts/gen_image_generic.sh"; then
    "$ROOT_DIR/scripts/patch-openwrt-x86-writable-extent.sh" \
      "$IB_DIR/scripts/gen_image_generic.sh"
  fi
  grep -q 'ROOTFS_SIZE_SPEC' "$IB_DIR/scripts/gen_image_generic.sh" || {
    printf 'Could not install exact writable-extent support in ImageBuilder\n' >&2
    exit 1
  }
  ROOTFS_WRITABLE_KIB="$WRITABLE_BUDGET_KIB"
  export ROOTFS_WRITABLE_KIB
fi

make -s -C "$IB_DIR" info > "$PROFILE_INFO"
awk -v profile="$PROFILE" '$0 == profile ":" { found=1 } END { exit !found }' "$PROFILE_INFO" || {
  printf 'Profile %s is not present in the OpenWrt %s %s ImageBuilder\n' \
    "$PROFILE" "$OPENWRT_VERSION" "$TARGET_DIR" >&2
  exit 1
}
if [ "$TARGET_DIR" = "x86/64" ]; then
  # The release and VM gate boot the combined squashfs image. Building the
  # unused ext4 variant can mask the exact squashfs/overlay contract.
  sed -i 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y$/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' "$IB_DIR/.config"
  grep -q '^# CONFIG_TARGET_ROOTFS_EXT4FS is not set$' "$IB_DIR/.config" || {
    printf 'Could not disable the unused x86 ext4 image variant\n' >&2
    exit 1
  }
fi

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
EXPECTED_RELEASE_PUBLIC="$WORK_DIR/canonical-package-release.pub"
EXPECTED_RELEASE_KEY_ID="$WORK_DIR/canonical-package-release-key-id"
tar -xzOf "$PROJECT_PACKAGE_DIR/premier-router-core_${PKG_VERSION}_all.ipk" ./data.tar.gz |
  tar -xzOf - ./usr/share/premier-router/keys/release.pub > "$EXPECTED_RELEASE_PUBLIC"
tar -xzOf "$PROJECT_PACKAGE_DIR/premier-router-core_${PKG_VERSION}_all.ipk" ./data.tar.gz |
  tar -xzOf - ./usr/share/premier-router/keys/release-key-id > "$EXPECTED_RELEASE_KEY_ID"
cmp -s "$INSTALLED_PACKAGE_SET_DIR/release.pub" "$EXPECTED_RELEASE_PUBLIC" || {
  printf 'Installed package set uses another public key\n' >&2
  exit 1
}
cmp -s "$INSTALLED_PACKAGE_SET_DIR/release-key-id" "$EXPECTED_RELEASE_KEY_ID" || {
  printf 'Installed package set uses another release key ID\n' >&2
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

if [ -z "$IMAGEBUILDER_LOCAL_KEY_FINGERPRINT" ]; then
  IMAGEBUILDER_LOCAL_KEY_FINGERPRINT="$(
    "$IB_DIR/staging_dir/host/bin/usign" -F -p "$IB_DIR/key-build.pub"
  )"
fi
printf '%s\n' "$IMAGEBUILDER_LOCAL_KEY_FINGERPRINT" |
  grep -Eq '^[0-9a-f]{16}$' || {
    printf 'Could not determine the ImageBuilder local public-key fingerprint\n' >&2
    exit 1
  }

# ImageBuilder's CycloneDX generator adds a random serial UUID, wall-clock
# timestamp, and filesystem-order components. Normalize only that metadata;
# package and image payload bytes remain untouched and separately hashed.
BOM_SERIAL_SEED="$(printf '%s' "$SOURCE_COMMIT" | sha256sum | awk '{print $1}')"
BOM_SERIAL_UUID="$(printf '%s\n' "$BOM_SERIAL_SEED" |
  awk '{print substr($0,1,8) "-" substr($0,9,4) "-" substr($0,13,4) "-" substr($0,17,4) "-" substr($0,21,12)}')"
BOM_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
find "$TARGET_OUT" -maxdepth 1 -type f -name '*.bom.cdx.json' -print |
  LC_ALL=C sort |
  while IFS= read -r bom_file; do
    normalized_bom="$bom_file.normalized"
    jq -S --arg serial "urn:uuid:$BOM_SERIAL_UUID" --arg timestamp "$BOM_TIMESTAMP" '
      .serialNumber = $serial |
      .metadata.timestamp = $timestamp |
      if (.components | type) == "array" then
        .components |= sort_by(
          .type // "",
          .name // "",
          .version // "",
          .["bom-ref"] // ""
        )
      else
        .
      end
    ' "$bom_file" > "$normalized_bom"
    mv "$normalized_bom" "$bom_file"
  done

RD23_STORAGE_LAYOUT=null
STORAGE_PROFILE=none
EXPECTED_UBIFS_DF_TOTAL_KIB=0
X86_ROOTFS_PARTSIZE_KIB=0
case "$PROFILE" in
  xiaomi_mi-router-ax3000t)
    STORAGE_PROFILE=rd23-stock
    STORAGE_IMAGE="$(find "$TARGET_OUT" -maxdepth 1 -type f \
      -name '*xiaomi_mi-router-ax3000t-squashfs-sysupgrade.bin' | sed -n '1p')"
    [ -n "$STORAGE_IMAGE" ] || { printf 'Missing RD23 stock sysupgrade image\n' >&2; exit 1; }
    RD23_STORAGE_LAYOUT="$("$ROOT_DIR/scripts/derive-rd23-storage-layout.sh" \
      "$STORAGE_PROFILE" "$STORAGE_IMAGE")"
    WRITABLE_BUDGET_KIB="$(printf '%s\n' "$RD23_STORAGE_LAYOUT" | jq -r '.rootfs_data_volume_kib')"
    EXPECTED_UBIFS_DF_TOTAL_KIB="$(printf '%s\n' "$RD23_STORAGE_LAYOUT" | jq -r '.expected_ubifs_df_total_kib')"
    ;;
  xiaomi_mi-router-ax3000t-ubootmod)
    STORAGE_PROFILE=rd23-ubootmod
    STORAGE_IMAGE="$(find "$TARGET_OUT" -maxdepth 1 -type f \
      -name '*xiaomi_mi-router-ax3000t-ubootmod-squashfs-sysupgrade.itb' | sed -n '1p')"
    [ -n "$STORAGE_IMAGE" ] || { printf 'Missing RD23 ubootmod sysupgrade image\n' >&2; exit 1; }
    RD23_STORAGE_LAYOUT="$("$ROOT_DIR/scripts/derive-rd23-storage-layout.sh" \
      "$STORAGE_PROFILE" "$STORAGE_IMAGE")"
    WRITABLE_BUDGET_KIB="$(printf '%s\n' "$RD23_STORAGE_LAYOUT" | jq -r '.rootfs_data_volume_kib')"
    EXPECTED_UBIFS_DF_TOTAL_KIB="$(printf '%s\n' "$RD23_STORAGE_LAYOUT" | jq -r '.expected_ubifs_df_total_kib')"
    ;;
  generic)
    [ "$TARGET_DIR" = "x86/64" ] || { printf 'Unexpected generic target\n' >&2; exit 1; }
    [ "$WRITABLE_BUDGET_KIB" -gt 0 ] || { printf 'x86 writable budget is required\n' >&2; exit 1; }
    STORAGE_PROFILE=rd23-stock
    SQUASHFS_BYTES="$(stat -c %s "$IB_DIR"/build_dir/target-*/linux-*/root.squashfs)"
    OVERLAY_OFFSET_BYTES=$(((SQUASHFS_BYTES + 65535) / 65536 * 65536))
    X86_ROOTFS_PARTSIZE_KIB=$((OVERLAY_OFFSET_BYTES / 1024 + WRITABLE_BUDGET_KIB))
    ;;
esac

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
if [ "$TARGET_DIR" = "x86/64" ]; then
  find "$PROFILE_ARTIFACT_DIR" -maxdepth 1 -type f -name '*ext4*' | grep -q . && {
    printf 'x86 artifact unexpectedly contains an ext4 variant\n' >&2
    exit 1
  }
  find "$PROFILE_ARTIFACT_DIR" -maxdepth 1 -type f -name '*squashfs-combined.img.gz' | grep -q . || {
    printf 'x86 artifact lacks the mandatory combined squashfs image\n' >&2
    exit 1
  }
fi
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
cp "$ROOT_DIR/release/rd23-storage-geometry.json" \
  "$PROFILE_ARTIFACT_DIR/rd23-storage-geometry.json"
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
  "imagebuilder_local_key_mode": "$IMAGEBUILDER_LOCAL_KEY_MODE",
  "imagebuilder_local_key_fingerprint": "$IMAGEBUILDER_LOCAL_KEY_FINGERPRINT",
  "updater_protocol": 2,
  "storage_profile": "$STORAGE_PROFILE",
  "writable_budget_kib": $WRITABLE_BUDGET_KIB,
  "writable_backing_kib": $WRITABLE_BUDGET_KIB,
  "expected_ubifs_df_total_kib": $EXPECTED_UBIFS_DF_TOTAL_KIB,
  "x86_rootfs_partsize_mib": $ROOTFS_PARTSIZE,
  "x86_rootfs_partsize_kib": $X86_ROOTFS_PARTSIZE_KIB,
  "rd23_storage_layout": $RD23_STORAGE_LAYOUT
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
