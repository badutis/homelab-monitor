#!/usr/bin/env bash
# Markdown release notes for a release: component versions from sources.lock,
# the assets with sizes, how to verify and use them, the vulnerability scan
# summary and the license/source offer.
#
# Usage: scripts/release-notes.sh <tag> <assets-dir>

set -euo pipefail

tag="${1:?usage: release-notes.sh <tag> <assets-dir>}"
assets="${2:?usage: release-notes.sh <tag> <assets-dir>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
lock="$repo_root/sources.lock"
repo="${GITHUB_REPOSITORY:-badutis/homelab-monitor}"

field() { grep -E "^$1[[:space:]]" "$lock" | tr -s '[:space:]' '\n' | sed -n "s/^$2=//p"; }

images=("$assets"/*.img.xz)
[ -f "${images[0]}" ] || {
  echo "error: no .img.xz in $assets" >&2
  exit 1
}
image="$(basename "${images[0]}")"

cat <<EOF
Armbian image for the **Makerbase MKS Pi** (RK3328, 1 GB) that monitors a homelab: VictoriaMetrics, Grafana, node_exporter and the homelable map behind one nginx entry point.

## Contents

| Component | Version |
|---|---|
| Armbian framework ([armbian-mkspi](https://github.com/redrathnure/armbian-mkspi)) | \`$(field armbian-mkspi tag)\` |
| Debian | 13 (trixie), minimal |
| Linux kernel | \`$(field linux tag)\` (Armbian \`current\`, frozen) |
| VictoriaMetrics | \`$(field victoriametrics version)\` |
| Grafana OSS | \`$(field grafana version)\` |
| homelable | \`$(field homelable tag)\` |

## Install

1. Write \`$image\` to an SD card (e.g. \`xzcat $image | sudo dd of=/dev/sdX bs=4M conv=fsync\`, or balenaEtcher).
2. Copy [\`homelab.env.example\`](https://github.com/$repo/blob/$tag/homelab.env.example) to the card's boot partition as \`homelab.env\` and fill in at least the user and SSH key.
3. Boot. Then open \`http://<box>/\` (homelable) and \`http://<box>/grafana/\`; generated passwords are in \`/root/homelab-credentials.txt\`.

See the [README](https://github.com/$repo/blob/$tag/README.md) for the configuration and security model.

## Verify

\`\`\`
sha256sum -c SHA256SUMS
gh attestation verify $image --repo $repo
\`\`\`

Every asset has a build provenance attestation: it was built by this repository's release workflow from tag \`$tag\`.

## Assets

| File | Size |
|---|---|
EOF
(cd "$assets" && for f in *; do
  # shellcheck disable=SC2016 # backticks are Markdown, not a command
  printf '| `%s` | %s |\n' "$f" "$(du -h "$f" | cut -f1)"
done)

if [ -f "$assets/trivy-summary.md" ]; then
  echo
  sed 's/^### /## /' "$assets/trivy-summary.md"
fi

cat <<EOF

## Licenses and sources

The image contains software under GPL-2.0, AGPL-3.0, MIT, Apache-2.0, NPSL and other licenses; see [THIRD_PARTY.md](https://github.com/$repo/blob/$tag/THIRD_PARTY.md). Corresponding sources attached to this release:

- \`linux-source.tar.xz\`, \`u-boot-source.tar.xz\`, \`arm-trusted-firmware-source.tar.xz\` — as built, with Armbian's patches (\`SOURCES.txt\` lists the commits);
- \`armbian-mkspi-src.tar.gz\` — the build framework;
- \`grafana-*-source.tar.gz\` — Grafana OSS (AGPL-3.0);
- Debian packages: \`packages.tsv\` lists package and source versions, available from [snapshot.debian.org](https://snapshot.debian.org/);
- this repository at tag \`$tag\` — the build scripts and configuration (GPL-2.0).
EOF
