#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
TARGET_DIR="${TARGET_DIR:-x86/64}"
PROFILE="${PROFILE:-generic}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-512}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.imagebuilder}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
IB_NAME="openwrt-imagebuilder-$OPENWRT_VERSION-x86-64.Linux-x86_64"
IB_ARCHIVE="$IB_NAME.tar.zst"
IB_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/$TARGET_DIR/$IB_ARCHIVE"
IB_DIR="$WORK_DIR/$IB_NAME"
OVERLAY="$WORK_DIR/overlay"
PACKAGE_FILE="$ROOT_DIR/image/openwrt-fin0-packages.txt"
PROJECT_PACKAGE_DIR="${PROJECT_PACKAGE_DIR:-$ROOT_DIR/dist/ipk}"
PROJECT_PACKAGES="${PROJECT_PACKAGES:-premier-router-core luci-app-premier-router premier-router-setup}"
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

for tool in curl tar zstd make sha256sum; do
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

mkdir -p "$WORK_DIR" "$OUT_DIR"

for pkg in $PROJECT_PACKAGES; do
  ls "$PROJECT_PACKAGE_DIR/${pkg}_"*.ipk >/dev/null 2>&1 || {
    printf 'Missing prebuilt project package for %s in %s\n' "$pkg" "$PROJECT_PACKAGE_DIR" >&2
    printf 'Run ./scripts/build-openwrt-ipks.sh before building images.\n' >&2
    exit 1
  }
done

if [ ! -d "$IB_DIR" ]; then
  if [ ! -f "$WORK_DIR/$IB_ARCHIVE" ]; then
    printf 'Downloading ImageBuilder %s...\n' "$OPENWRT_VERSION"
    curl -fL --connect-timeout 15 --max-time 600 "$IB_URL" -o "$WORK_DIR/$IB_ARCHIVE"
  else
    printf 'Using preloaded ImageBuilder archive: %s\n' "$WORK_DIR/$IB_ARCHIVE"
  fi
  tar --use-compress-program=unzstd -xf "$WORK_DIR/$IB_ARCHIVE" -C "$WORK_DIR"
fi

install_project_feed() {
  pkg_dir="$IB_DIR/packages"
  mkdir -p "$pkg_dir"
  cp "$PROJECT_PACKAGE_DIR"/*.ipk "$pkg_dir/"
  if [ -x "$IB_DIR/scripts/ipkg-make-index.sh" ]; then
    (
      cd "$IB_DIR"
      ./scripts/ipkg-make-index.sh packages > packages/Packages
      gzip -kf packages/Packages
    )
  fi
  if [ -x "$IB_DIR/staging_dir/host/bin/usign" ] && [ -f "$IB_DIR/key-build" ]; then
    (
      cd "$IB_DIR"
      staging_dir/host/bin/usign -S -m packages/Packages -s key-build -x packages/Packages.sig >/dev/null 2>&1 || true
    )
  fi
}

install_project_feed

rm -rf "$OVERLAY"
mkdir -p "$OVERLAY/www"
copy_root_redirect="$ROOT_DIR/image-overlay/www/index.html"
if [ -f "$copy_root_redirect" ]; then
  cp "$copy_root_redirect" "$OVERLAY/www/index.html"
  chmod 644 "$OVERLAY/www/index.html"
fi

PACKAGES="$(awk 'NF && $1 !~ /^#/ { printf "%s ", $1 }' "$PACKAGE_FILE") $PROJECT_PACKAGES"

printf 'Building OpenWrt %s x86/64 image...\n' "$OPENWRT_VERSION"
make -C "$IB_DIR" image \
  PROFILE="$PROFILE" \
  PACKAGES="$PACKAGES" \
  FILES="$OVERLAY" \
  ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"

EFI_IMAGE="$(find "$IB_DIR/bin/targets/x86/64" -maxdepth 1 -type f \
  -name '*generic-ext4-combined-efi.img.gz' | sort | tail -n 1)"
BIOS_IMAGE="$(find "$IB_DIR/bin/targets/x86/64" -maxdepth 1 -type f \
  -name '*generic-ext4-combined.img.gz' | sort | tail -n 1)"
[ -n "$EFI_IMAGE" ] && [ -n "$BIOS_IMAGE" ] || {
  printf 'ImageBuilder did not produce an ext4 combined EFI image.\n' >&2
  exit 1
}

EFI_DEST="$OUT_DIR/premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-x86-64-ext4-combined-efi.img.gz"
BIOS_DEST="$OUT_DIR/premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-x86-64-ext4-combined.img.gz"
cp "$EFI_IMAGE" "$EFI_DEST"
cp "$BIOS_IMAGE" "$BIOS_DEST"
sha256sum "$EFI_DEST" > "$EFI_DEST.sha256"
sha256sum "$BIOS_DEST" > "$BIOS_DEST.sha256"

printf 'Built EFI image: %s\n' "$EFI_DEST"
printf 'Built BIOS image: %s\n' "$BIOS_DEST"
