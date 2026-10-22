#!/usr/bin/env bash
# Build the MKS Pi image from source with the Armbian framework pinned in
# sources.lock. Linux only (Ubuntu 24.04 host, as on GitHub runners); needs
# sudo and roughly 40 GB of free disk.
#
# Usage: scripts/build-image.sh [work-dir]
#   work-dir defaults to ./.work; outputs land in <work-dir>/out/.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="${1:-$repo_root/.work}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
armbian="$work/armbian-mkspi"
out="$work/out"

if [ ! -d "$armbian" ]; then
  "$repo_root/scripts/fetch-source.sh" armbian-mkspi "$armbian"
fi

# Kernel version is pinned in sources.lock; verify the tag before building.
"$repo_root/scripts/fetch-source.sh" linux --verify-only
kernel_tag="$(grep -E '^linux[[:space:]]' "$repo_root/sources.lock" |
  tr -s '[:space:]' '\n' | sed -n 's/^tag=//p')"

# Our additions go in through the framework's own userpatches mechanism; the
# framework itself is never modified.
rm -rf "$armbian/userpatches"
cp -R "$repo_root/build/userpatches" "$armbian/userpatches"

# shellcheck disable=SC2054 # "sha,xz" is one value, not two array elements
build_args=(
  BOARD=mkspi
  BRANCH=current
  RELEASE=trixie
  BUILD_MINIMAL=yes
  BUILD_DESKTOP=no
  KERNEL_CONFIGURE=no
  # Fixed kernel tag instead of the rolling stable branch.
  "KERNELBRANCH=tag:${kernel_tag}"
  # Kernel and u-boot are not upgraded through apt; a new image replaces them.
  BSPFREEZE=yes
  # Build everything from source: never download prebuilt kernel, u-boot or
  # rootfs artifacts from the Armbian cache.
  ARTIFACT_IGNORE_CACHE=yes
  # Native build on the Ubuntu 24.04 host instead of a Docker container.
  PREFER_DOCKER=no
  SHARE_LOG=no
  COMPRESS_OUTPUTIMAGE=sha,xz
)

(cd "$armbian" && sudo ./compile.sh build "${build_args[@]}")

mkdir -p "$out"
sudo find "$armbian/output/images" -maxdepth 1 -type f \
  \( -name '*.img.xz' -o -name '*.img.xz.sha' \) -exec cp {} "$out/" \;
sudo tar -C "$armbian/output" -czf "$out/build-logs.tar.gz" logs
sudo chown -R "$(id -u):$(id -g)" "$out"

# Source of the pinned framework (GPL-2.0), shipped next to the image.
git -c safe.directory="$armbian" -C "$armbian" archive --format=tar.gz --prefix=armbian-mkspi/ \
  -o "$out/armbian-mkspi-src.tar.gz" HEAD

# Record exactly what was built (pinned framework commit and build settings).
{
  echo "homelab-monitor commit: $(git -C "$repo_root" rev-parse HEAD)"
  echo "armbian-mkspi commit:   $(git -c safe.directory="$armbian" -C "$armbian" rev-parse HEAD)"
  echo "build arguments:"
  printf '  %s\n' "${build_args[@]}"
} >"$out/BUILD-INFO.txt"

ls -l "$out"
