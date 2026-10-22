#!/usr/bin/env bash
# List the Debian packages installed in a mounted image (see
# scripts/with-image-rootfs.sh): one line per package with version, source
# package and source version, the reference for getting Debian sources from
# snapshot.debian.org.
#
#   scripts/with-image-rootfs.sh image.img.xz scripts/image-manifest.sh <out-file>

set -euo pipefail

root="${ROOTFS:?run through scripts/with-image-rootfs.sh}"
out="${1:?usage: image-manifest.sh <out-file>}"

{
  printf 'package\tversion\tarchitecture\tsource\tsource_version\n'
  dpkg-query --admindir="$root/var/lib/dpkg" -W \
    -f='${Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\n' |
    sort
} >"$out"
echo "$(($(wc -l <"$out") - 1)) packages listed in $out"
