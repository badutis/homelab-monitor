#!/usr/bin/env bash
# Fetch one component from sources.lock at its pinned tag and verify that the
# tag still points to the recorded commit.
#
# Usage: scripts/fetch-source.sh <name> <destination-dir>
#        scripts/fetch-source.sh <name> --verify-only

set -euo pipefail

name="${1:?usage: fetch-source.sh <name> <destination-dir>}"
dest="${2:?usage: fetch-source.sh <name> <destination-dir>}"
lock="$(cd "$(dirname "$0")/.." && pwd)/sources.lock"

line="$(grep -E "^${name}[[:space:]]" "$lock" || true)"
[ -n "$line" ] || { echo "error: '$name' not found in sources.lock" >&2; exit 1; }

field() { printf '%s\n' "$line" | tr -s '[:space:]' '\n' | sed -n "s/^$1=//p"; }
repo="$(field repo)"
tag="$(field tag)"
commit="$(field commit)"
for v in repo tag commit; do
  [ -n "${!v}" ] || { echo "error: '$name' has no $v= in sources.lock" >&2; exit 1; }
done

# --verify-only: check that the tag still resolves to the pinned commit
# without cloning (for large repositories fetched by the build framework).
if [ "$dest" = "--verify-only" ]; then
  actual="$(git ls-remote "$repo" "refs/tags/${tag}^{}" "refs/tags/${tag}" \
    | awk 'NR==1 || /\^\{\}$/ {sha=$1} END {print sha}')"
  if [ "$actual" != "$commit" ]; then
    echo "error: $name tag $tag points to ${actual:-nothing}, sources.lock expects $commit" >&2
    exit 1
  fi
  echo "$name: $tag = $commit (verified)"
  exit 0
fi

if [ -e "$dest" ]; then
  echo "error: $dest already exists" >&2
  exit 1
fi

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$repo" "$dest"
actual="$(git -C "$dest" rev-parse HEAD)"
if [ "$actual" != "$commit" ]; then
  echo "error: $name tag $tag points to $actual, sources.lock expects $commit" >&2
  exit 1
fi
echo "$name: $tag = $commit (verified)"
