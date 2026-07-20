#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GEOMETRY="${RD23_STORAGE_GEOMETRY:-$ROOT_DIR/release/rd23-storage-geometry.json}"
PROFILE="${1:-}"
IMAGE="${2:-}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for tool in awk jq tar wc; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done
[ -s "$GEOMETRY" ] || fail "missing RD23 storage geometry: $GEOMETRY"
[ -s "$IMAGE" ] || fail "missing RD23 image payload: $IMAGE"
case "$PROFILE" in rd23-stock|rd23-ubootmod) ;; *) fail "unsupported RD23 storage profile: $PROFILE" ;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rd23-storage.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

peb_bytes="$(jq -r '.nand.physical_eraseblock_bytes' "$GEOMETRY")"
leb_bytes="$(jq -r '.nand.logical_eraseblock_bytes' "$GEOMETRY")"
partition_bytes="$(jq -r --arg profile "$PROFILE" '.profiles[$profile].ubi_partition_bytes' "$GEOMETRY")"
bad_reserve="$(jq -r '.nand.bad_peb_reserve' "$GEOMETRY")"
layout_pebs="$(jq -r '.nand.layout_volume_pebs' "$GEOMETRY")"
wl_pebs="$(jq -r '.nand.wear_leveling_pebs' "$GEOMETRY")"
fastmap_copies="$(jq -r '.nand.fastmap_copies' "$GEOMETRY")"
fastmap_fixed="$(jq -r '.nand.fastmap_fixed_bytes' "$GEOMETRY")"
fastmap_per_peb="$(jq -r '.nand.fastmap_bytes_per_peb' "$GEOMETRY")"

[ $((partition_bytes % peb_bytes)) -eq 0 ] || fail "UBI partition is not PEB-aligned"
partition_pebs=$((partition_bytes / peb_bytes))
fastmap_bytes=$((fastmap_fixed + fastmap_per_peb * partition_pebs))
fastmap_lebs=$(((fastmap_bytes + leb_bytes - 1) / leb_bytes))
[ "$fastmap_lebs" -eq 1 ] || fail "RD23 fastmap no longer fits one LEB"

case "$PROFILE" in
  rd23-stock)
    member="$(tar -tf "$IMAGE" | awk '/\/root$/ { print; exit }')"
    [ -n "$member" ] || fail "stock sysupgrade image has no root payload"
    tar -xOf "$IMAGE" "$member" > "$TMP/payload"
    payload_bytes="$(wc -c < "$TMP/payload" | tr -d ' ')"
    payload_kind=sysupgrade-root
    ;;
  rd23-ubootmod)
    payload_bytes="$(wc -c < "$IMAGE" | tr -d ' ')"
    payload_kind=complete-fit
    ;;
esac

payload_lebs=$(((payload_bytes + leb_bytes - 1) / leb_bytes))
fixed_volumes="$(jq -c --arg profile "$PROFILE" \
  '.profiles[$profile].fixed_volumes' "$GEOMETRY")"
fixed_volume_bytes="$(jq -r --arg profile "$PROFILE" \
  '[.profiles[$profile].fixed_volumes[].size_bytes] | add // 0' "$GEOMETRY")"
fixed_volume_lebs="$(jq -r --arg profile "$PROFILE" --argjson leb "$leb_bytes" \
  '[.profiles[$profile].fixed_volumes[].size_bytes | ((. + $leb - 1) / $leb | floor)] | add // 0' \
  "$GEOMETRY")"
ubi_reserved_pebs=$((layout_pebs + bad_reserve + wl_pebs + fastmap_copies * fastmap_lebs))
rootfs_data_lebs=$((partition_pebs - ubi_reserved_pebs - fixed_volume_lebs - payload_lebs))
[ "$rootfs_data_lebs" -gt 0 ] || fail "image payload leaves no rootfs_data volume"
rootfs_data_bytes=$((rootfs_data_lebs * leb_bytes))
rootfs_data_kib=$((rootfs_data_bytes / 1024))

jnl_percent="$(jq -r '.ubifs.journal_percent' "$GEOMETRY")"
jnl_min="$(jq -r '.ubifs.minimum_journal_lebs' "$GEOMETRY")"
jnl_max_bytes="$(jq -r '.ubifs.maximum_journal_bytes' "$GEOMETRY")"
jnl_lebs=$((rootfs_data_lebs * jnl_percent / 100))
[ "$jnl_lebs" -ge "$jnl_min" ] || jnl_lebs="$jnl_min"
jnl_max_lebs=$((jnl_max_bytes / leb_bytes))
[ "$jnl_lebs" -le "$jnl_max_lebs" ] || jnl_lebs="$jnl_max_lebs"

ref_bytes="$(jq -r '.ubifs.reference_node_aligned_bytes' "$GEOMETRY")"
log_lebs=$(((2 * ref_bytes * jnl_lebs + leb_bytes - 1) / leb_bytes + 1))
sb_lebs="$(jq -r '.ubifs.superblock_lebs' "$GEOMETRY")"
mst_lebs="$(jq -r '.ubifs.master_lebs' "$GEOMETRY")"
min_log="$(jq -r '.ubifs.minimum_log_lebs' "$GEOMETRY")"
min_bud="$(jq -r '.ubifs.minimum_bud_lebs' "$GEOMETRY")"
min_orph="$(jq -r '.ubifs.minimum_orphan_lebs' "$GEOMETRY")"
lpt_lebs="$(jq -r '.ubifs.lpt_lebs' "$GEOMETRY")"
min_leb_count=$((sb_lebs + mst_lebs + min_log + 2 * min_bud + min_orph + lpt_lebs))
if [ $((rootfs_data_lebs - min_leb_count)) -gt 8 ]; then log_lebs=$((log_lebs + 1)); fi
orph_lebs="$min_orph"
if [ $((rootfs_data_lebs - min_leb_count)) -gt 1 ]; then orph_lebs=$((orph_lebs + 1)); fi

main_lebs=$((rootfs_data_lebs - sb_lebs - mst_lebs - log_lebs - orph_lebs - lpt_lebs))
min_index="$(jq -r '.ubifs.minimum_index_lebs' "$GEOMETRY")"
jheads="$(jq -r '.ubifs.journal_heads' "$GEOMETRY")"
reported_lebs=$((main_lebs - 1 - 1 - min_index - jheads + 1))
[ "$reported_lebs" -gt 0 ] || fail "invalid derived UBIFS main area"
max_data_node="$(jq -r '.ubifs.maximum_data_node_bytes' "$GEOMETRY")"
block_bytes="$(jq -r '.ubifs.block_bytes' "$GEOMETRY")"
leb_overhead=$((leb_bytes % max_data_node))
reported_bytes=$((reported_lebs * (leb_bytes - leb_overhead)))
df_blocks=$((reported_bytes / block_bytes))
df_total_kib=$((df_blocks * block_bytes / 1024))

jq -n \
  --arg profile "$PROFILE" \
  --arg payload_kind "$payload_kind" \
  --arg openwrt_version "$(jq -r '.openwrt.version' "$GEOMETRY")" \
  --arg openwrt_commit "$(jq -r '.openwrt.commit' "$GEOMETRY")" \
  --argjson partition_bytes "$partition_bytes" \
  --argjson partition_pebs "$partition_pebs" \
  --argjson peb_bytes "$peb_bytes" \
  --argjson leb_bytes "$leb_bytes" \
  --argjson payload_bytes "$payload_bytes" \
  --argjson payload_lebs "$payload_lebs" \
  --argjson fixed_volumes "$fixed_volumes" \
  --argjson fixed_volume_bytes "$fixed_volume_bytes" \
  --argjson fixed_volume_lebs "$fixed_volume_lebs" \
  --argjson ubi_reserved_pebs "$ubi_reserved_pebs" \
  --argjson rootfs_data_lebs "$rootfs_data_lebs" \
  --argjson rootfs_data_bytes "$rootfs_data_bytes" \
  --argjson rootfs_data_kib "$rootfs_data_kib" \
  --argjson expected_df_total_kib "$df_total_kib" \
  --argjson journal_lebs "$jnl_lebs" \
  --argjson log_lebs "$log_lebs" \
  --argjson lpt_lebs "$lpt_lebs" \
  --argjson main_lebs "$main_lebs" \
  '{schema_version:1,profile:$profile,payload_kind:$payload_kind,
    openwrt_version:$openwrt_version,openwrt_commit:$openwrt_commit,
    ubi_partition_bytes:$partition_bytes,ubi_partition_pebs:$partition_pebs,
    physical_eraseblock_bytes:$peb_bytes,logical_eraseblock_bytes:$leb_bytes,
    payload_bytes:$payload_bytes,payload_lebs:$payload_lebs,
    fixed_volumes:$fixed_volumes,
    fixed_volume_bytes:$fixed_volume_bytes,fixed_volume_lebs:$fixed_volume_lebs,
    ubi_reserved_pebs:$ubi_reserved_pebs,rootfs_data_lebs:$rootfs_data_lebs,
    rootfs_data_volume_bytes:$rootfs_data_bytes,
    rootfs_data_volume_kib:$rootfs_data_kib,
    expected_ubifs_df_total_kib:$expected_df_total_kib,
    ubifs_geometry:{journal_lebs:$journal_lebs,log_lebs:$log_lebs,
      lpt_lebs:$lpt_lebs,main_lebs:$main_lebs}}' | jq -S .
