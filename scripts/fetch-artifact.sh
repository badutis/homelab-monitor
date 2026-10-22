#!/usr/bin/env bash
# Download a release artifact listed in sources.lock and verify its SHA256.
# The file keeps the basename of its URL; a mismatch deletes it and fails.
#
# Usage: scripts/fetch-artifact.sh <name> <destination-dir>

set -euo pipefail

name="${1:?usage: fetch-artifact.sh <name> <destination-dir>}"
dest="${2:?usage: fetch-artifact.sh <name> <destination-dir>}"
lock="$(cd "$(dirname "$0")/.." && pwd)/sources.lock"

line="$(grep -E "^${name}[[:space:]]" "$lock" || true)"
[ -n "$line" ] || {
  echo "error: '$name' not found in sources.lock" >&2
  exit 1
}

field() { printf '%s\n' "$line" | tr -s '[:space:]' '\n' | sed -n "s/^$1=//p"; }
url="$(field url)"
sha256="$(field sha256)"
for v in url sha256; do
  [ -n "${!v}" ] || {
    echo "error: '$name' has no $v= in sources.lock" >&2
    exit 1
  }
done
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "error: '$name' sha256 is not 64 hex digits" >&2
  exit 1
}

mkdir -p "$dest"
file="$dest/$(basename "$url")"
curl -fsSL --retry 3 -o "$file.part" "$url"
actual="$(sha256sum "$file.part" 2>/dev/null || shasum -a 256 "$file.part")"
actual="${actual%% *}"
if [ "$actual" != "$sha256" ]; then
  rm -f "$file.part"
  echo "error: $name sha256 is $actual, sources.lock expects $sha256" >&2
  exit 1
fi
mv "$file.part" "$file"
echo "$name: $(basename "$file") (sha256 verified)"
