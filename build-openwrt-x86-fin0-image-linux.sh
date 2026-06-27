#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VERSION="${VERSION:-24.10.5}"
TARGET_DIR="${TARGET_DIR:-x86/64}"
PROFILE="${PROFILE:-generic}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-512}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.imagebuilder}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
IB_NAME="openwrt-imagebuilder-$VERSION-x86-64.Linux-x86_64"
IB_ARCHIVE="$IB_NAME.tar.zst"
IB_URL="https://downloads.openwrt.org/releases/$VERSION/targets/$TARGET_DIR/$IB_ARCHIVE"
IB_DIR="$WORK_DIR/$IB_NAME"
OVERLAY="$WORK_DIR/overlay"
PACKAGE_FILE="$ROOT_DIR/image/openwrt-fin0-packages.txt"
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

mkdir -p "$WORK_DIR" "$OUT_DIR"

if [ ! -d "$IB_DIR" ]; then
  if [ ! -f "$WORK_DIR/$IB_ARCHIVE" ]; then
    printf 'Downloading ImageBuilder %s...\n' "$VERSION"
    curl -fL --connect-timeout 15 --max-time 600 "$IB_URL" -o "$WORK_DIR/$IB_ARCHIVE"
  else
    printf 'Using preloaded ImageBuilder archive: %s\n' "$WORK_DIR/$IB_ARCHIVE"
  fi
  tar --use-compress-program=unzstd -xf "$WORK_DIR/$IB_ARCHIVE" -C "$WORK_DIR"
fi

rm -rf "$OVERLAY"
mkdir -p "$OVERLAY/www/setup"
cp -R "$ROOT_DIR/image-overlay/." "$OVERLAY/"
cp "$ROOT_DIR/firstboot-wizard/www/index.html" "$OVERLAY/www/setup/index.html"
cp "$ROOT_DIR/firstboot-wizard/www/styles.css" "$OVERLAY/www/setup/styles.css"
cp "$ROOT_DIR/firstboot-wizard/www/app.js" "$OVERLAY/www/setup/app.js"
cp -R "$ROOT_DIR/luci-vpn-ui/files/." "$OVERLAY/"

chmod 0755 \
  "$OVERLAY/etc/uci-defaults/99-openwrt-fin0-firstboot" \
  "$OVERLAY/www/cgi-bin/firstboot-setup" \
  "$OVERLAY/www/cgi-bin/router-prep" \
  "$OVERLAY/usr/sbin/router-prep" \
  "$OVERLAY/usr/sbin/vpn-ui" \
  "$OVERLAY/usr/sbin/vpn-ui-update"

PACKAGES="$(awk 'NF && $1 !~ /^#/ { printf "%s ", $1 }' "$PACKAGE_FILE")"

printf 'Building OpenWrt %s x86/64 image...\n' "$VERSION"
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

EFI_DEST="$OUT_DIR/openwrt-$VERSION-x86-64-openwrt-fin0-ext4-combined-efi.img.gz"
BIOS_DEST="$OUT_DIR/openwrt-$VERSION-x86-64-openwrt-fin0-ext4-combined.img.gz"
cp "$EFI_IMAGE" "$EFI_DEST"
cp "$BIOS_IMAGE" "$BIOS_DEST"
sha256sum "$EFI_DEST" > "$EFI_DEST.sha256"
sha256sum "$BIOS_DEST" > "$BIOS_DEST.sha256"

printf 'Built EFI image: %s\n' "$EFI_DEST"
printf 'Built BIOS image: %s\n' "$BIOS_DEST"
