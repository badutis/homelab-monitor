#!/usr/bin/env bash
# Prepare homelable for the image from the release pinned in sources.lock:
#
#   <out>/homelable-backend.tar.gz         backend/app, VERSION, LICENSE
#   <out>/homelable-frontend.tar.gz        built web UI (dist/), served by nginx
#   <out>/homelable-frontend-licenses.txt  licenses of the bundled npm packages
#   <out>/requirements.lock                Python runtime deps, SHA256-pinned
#   <out>/build-requirements.lock          setuptools for python-nmap, pinned
#
# The web UI is built here, not on the board: the build needs ~1.5 GB of RAM.
# npm runs with --ignore-scripts, so no package install script executes.
# Needs Node.js 22+ and npm.
#
# Usage: scripts/build-homelable.sh <out-dir> [<homelable source dir>]

set -euo pipefail

out="${1:?usage: build-homelable.sh <out-dir> [<homelable source dir>]}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

src="${2:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [ -z "$src" ]; then
  src="$tmp/homelable"
  "$repo_root/scripts/fetch-source.sh" homelable "$src"
fi

node_major="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
[ "$node_major" -ge 22 ] || {
  echo "error: Node.js 22 or newer is required (found $(node --version))" >&2
  exit 1
}

echo "building the homelable web UI"
(
  cd "$src/frontend"
  npm ci --ignore-scripts --no-audit --no-fund
  VITE_BASE_PATH=/ npm run build
)
[ -f "$src/frontend/dist/index.html" ] || {
  echo "error: frontend build produced no dist/index.html" >&2
  exit 1
}
tar -C "$src/frontend" -czf "$out/homelable-frontend.tar.gz" dist

# Licenses of the npm packages that end up in the bundle (production deps),
# from package-lock.json.
python3 - "$src/frontend/package-lock.json" >"$out/homelable-frontend-licenses.txt" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
rows = []
for path, meta in lock.get("packages", {}).items():
    if not path or meta.get("dev") or meta.get("devOptional"):
        continue
    name = path.split("node_modules/")[-1]
    rows.append(f"{name} {meta.get('version', '?')} {meta.get('license', 'UNKNOWN')}")
print("# npm packages bundled into the homelable web UI: name version license")
print("\n".join(sorted(set(rows))))
EOF

echo "packaging the homelable backend"
tar -C "$src" -czf "$out/homelable-backend.tar.gz" \
  --exclude='__pycache__' --exclude='*.pyc' \
  backend/app VERSION LICENSE

cp "$repo_root/build/homelable/requirements.lock" "$repo_root/build/homelable/build-requirements.lock" "$out/"
ls -l "$out"
