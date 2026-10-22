#!/usr/bin/env bash
# Scan a built image for known vulnerabilities and write an SBOM.
#
# Mounts the image root filesystem read-only and runs Trivy over it:
#   <out>/trivy-report.json   full vulnerability report
#   <out>/sbom.cdx.json       CycloneDX software bill of materials
#   <out>/trivy-summary.md    Markdown summary: counts by severity and by source
#   <out>/trivy.sarif         CRITICAL and HIGH findings as SARIF, for GitHub
#                             code scanning
#
# Report only for now: findings do not fail the build. Linux only, needs sudo
# and trivy in PATH.
#
# Usage: scripts/scan-image.sh <image.img.xz> <out-dir>

set -euo pipefail

image="${1:?usage: scan-image.sh <image.img.xz> <out-dir>}"
out="${2:?usage: scan-image.sh <image.img.xz> <out-dir>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

scan() {
  # Trivy reads the mounted tree; sudo because some files are root-only.
  sudo trivy rootfs --quiet --scanners vuln --format json \
    --output "$out/trivy-report.json" "$ROOTFS"
  sudo trivy rootfs --quiet --format cyclonedx \
    --output "$out/sbom.cdx.json" "$ROOTFS"
  sudo chown "$(id -u):$(id -g)" "$out/trivy-report.json" "$out/sbom.cdx.json"
  # Which Grafana bundled plugins the image loads, for the summary.
  if [ -f "$ROOTFS/etc/grafana/homelab-plugins.env" ]; then
    cat "$ROOTFS/etc/grafana/homelab-plugins.env" >"$out/grafana-plugins.env"
  fi
}
export -f scan
export out

"$repo_root/scripts/with-image-rootfs.sh" "$image" bash -c scan

# Summary by severity and by source (Debian, Grafana, plugins, VictoriaMetrics).
plugins_env=""
[ -s "$out/grafana-plugins.env" ] && plugins_env="$out/grafana-plugins.env"
python3 "$repo_root/scripts/scan-summary.py" "$out/trivy-report.json" \
  "$(basename "$image")" ${plugins_env:+"$plugins_env"} >"$out/trivy-summary.md"
rm -f "$out/grafana-plugins.env"

# SARIF for GitHub code scanning: only CRITICAL and HIGH, the rest would bury
# them (most lower findings are Debian packages without a fix yet).
trivy convert --quiet --format sarif --severity CRITICAL,HIGH \
  --output "$out/trivy.sarif" "$out/trivy-report.json"

cat "$out/trivy-summary.md"
