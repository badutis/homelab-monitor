#!/usr/bin/env bash
# Collect the corresponding source of the GPL parts of an image, as built:
# the Linux kernel, U-Boot and Trusted Firmware-A trees from the Armbian
# build cache, with Armbian's patches applied and the kernel .config.
#
#   <out>/linux-source.tar.xz
#   <out>/u-boot-source.tar.xz
#   <out>/arm-trusted-firmware-source.tar.xz
#   <out>/SOURCES.txt             what each archive contains (tree, commit)
#
# Only tracked and not-ignored files are archived (git ls-files), so build
# outputs stay out. Run as root after scripts/build-image.sh (the cache is
# root-owned).
#
# Usage: scripts/collect-sources.sh <armbian-mkspi dir> <out-dir>

set -euo pipefail

armbian="${1:?usage: collect-sources.sh <armbian dir> <out-dir>}"
out="${2:?usage: collect-sources.sh <armbian dir> <out-dir>}"
cache="$armbian/cache/sources"
mkdir -p "$out"

# The single directory matching a glob, or fail.
one_dir() {
  local matches=()
  for d in "$@"; do [ -d "$d" ] && matches+=("$d"); done
  if [ "${#matches[@]}" -ne 1 ]; then
    echo "error: expected one source tree, found ${#matches[@]}: $*" >&2
    exit 1
  fi
  printf '%s\n' "${matches[0]}"
}

# archive <name> <tree> [extra file relative to the tree]...
archive() {
  local name="$1" tree="$2" commit
  shift 2
  commit="$(git -c safe.directory='*' -C "$tree" rev-parse HEAD)"
  {
    git -c safe.directory='*' -C "$tree" ls-files -z --cached --others --exclude-standard
    for f in "$@"; do [ -f "$tree/$f" ] && printf '%s\0' "$f"; done
  } | tar -C "$tree" --null -T - --transform "s,^,$name/," -cf - |
    xz -T0 -6 >"$out/$name.tar.xz"
  printf '%-36s %s  (tree %s)\n' "$name.tar.xz" "$commit" "${tree#"$armbian/"}" >>"$out/SOURCES.txt"
  echo "$name: $(du -h "$out/$name.tar.xz" | cut -f1)"
}

{
  echo "Corresponding source of the GPL components of this image, as built"
  echo "(Armbian patches applied; the kernel archive includes its .config)."
  echo "archive                              HEAD commit of the patched tree"
} >"$out/SOURCES.txt"

archive linux-source "$(one_dir "$cache"/linux-kernel-worktree/*)" .config
archive u-boot-source "$(one_dir "$cache"/u-boot-worktree/u-boot/*)" .config
archive arm-trusted-firmware-source "$(one_dir "$cache"/arm-trusted-firmware/*)"

cat >>"$out/SOURCES.txt" <<'EOF'

Rockchip boot blobs (rkbin, e.g. the DDR init) are binary-only from
Rockchip and have no source. Debian packages: see packages.tsv; their
sources are on https://snapshot.debian.org/ for the listed versions. The
Armbian framework source is armbian-mkspi-src.tar.gz.
EOF
