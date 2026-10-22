#!/usr/bin/env bash
# Mount the root filesystem of a built image read-only and run a command
# against it. The mount point is passed in $ROOTFS; everything is unmounted
# and detached afterwards, also on failure. Linux only, needs sudo.
#
# Usage: scripts/with-image-rootfs.sh <image.img.xz|image.img> <command> [args...]

set -euo pipefail

image="${1:?usage: with-image-rootfs.sh <image> <command> [args...]}"
shift
[ "$#" -gt 0 ] || {
  echo "error: no command given" >&2
  exit 1
}

work="$(mktemp -d)"
loop=""
mnt="$work/rootfs"

cleanup() {
  if mountpoint -q "$mnt/boot" 2>/dev/null; then sudo umount "$mnt/boot"; fi
  if mountpoint -q "$mnt" 2>/dev/null; then sudo umount "$mnt"; fi
  if [ -n "$loop" ]; then sudo losetup -d "$loop"; fi
  rm -rf "$work"
}
trap cleanup EXIT

raw="$image"
case "$image" in
  *.xz)
    raw="$work/image.img"
    xz -dc "$image" >"$raw"
    ;;
esac

loop="$(sudo losetup --find --show --partscan --read-only "$raw")"
sudo udevadm settle || true

# The root filesystem is the ext4 partition; /boot is the FAT one.
root_part=""
boot_part=""
for p in "${loop}"p*; do
  case "$(sudo blkid -o value -s TYPE "$p" 2>/dev/null || true)" in
    ext4) root_part="$p" ;;
    vfat) boot_part="$p" ;;
  esac
done
[ -n "$root_part" ] || {
  echo "error: no ext4 partition found in $image" >&2
  exit 1
}

mkdir -p "$mnt"
sudo mount -o ro,noload "$root_part" "$mnt"
if [ -n "$boot_part" ] && [ -d "$mnt/boot" ]; then
  sudo mount -o ro "$boot_part" "$mnt/boot"
fi

ROOTFS="$mnt" "$@"
