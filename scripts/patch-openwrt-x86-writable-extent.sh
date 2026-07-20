#!/bin/sh
set -eu
umask 077

TARGET="${1:?ImageBuilder gen_image_generic.sh path is required}"
[ -f "$TARGET" ] || { printf 'Missing ImageBuilder script: %s\n' "$TARGET" >&2; exit 1; }

grep -q 'ROOTFS_WRITABLE_KIB' "$TARGET" && exit 0

TMP="$(mktemp "${TMPDIR:-/tmp}/gen-image-generic.XXXXXX")"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT INT TERM

awk '
  BEGIN { inserted = 0; replaced = 0 }
  {
    if ($0 == "ALIGN=\"$6\"") {
      print
      print "ROOTFS_SIZE_SPEC=\"${ROOTFSSIZE}m\""
      print "if [ -n \"${ROOTFS_WRITABLE_KIB:-}\" ]; then"
      print "\tSQUASHFS_BYTES=\"$(stat -c %s \"$ROOTFSIMAGE\")\""
      print "\tOVERLAY_OFFSET_BYTES=\"$(("
      print "\t\t(SQUASHFS_BYTES + 65535) / 65536 * 65536"
      print "\t))\""
      print "\tROOTFS_TOTAL_KIB=\"$((OVERLAY_OFFSET_BYTES / 1024 + ROOTFS_WRITABLE_KIB))\""
      print "\tROOTFS_SIZE_SPEC=\"${ROOTFS_TOTAL_KIB}k\""
      print "fi"
      inserted++
      next
    }
    if ($0 ~ /^set \$\(ptgen / && index($0, "-p \"${ROOTFSSIZE}m\"") > 0) {
      sub(/\$\{ROOTFSSIZE\}m/, "${ROOTFS_SIZE_SPEC}")
      replaced++
    }
    print
  }
  END { if (inserted != 1 || replaced != 1) exit 42 }
' "$TARGET" > "$TMP" || {
  printf 'Could not patch exact writable-extent support into %s\n' "$TARGET" >&2
  exit 1
}

chmod 755 "$TMP"
mv "$TMP" "$TARGET"
trap - EXIT INT TERM
