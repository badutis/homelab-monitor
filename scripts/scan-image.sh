#!/usr/bin/env bash
# Scan a built image for known vulnerabilities and write an SBOM.
#
# Mounts the image root filesystem read-only and runs Trivy over it:
#   <out>/trivy-report.json   full vulnerability report
#   <out>/sbom.cdx.json       CycloneDX software bill of materials
#   <out>/trivy-summary.md    short Markdown summary (counts by severity)
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
}
export -f scan
export out

"$repo_root/scripts/with-image-rootfs.sh" "$image" bash -c scan

# Summary: vulnerability counts by severity, and how many have a fix.
python3 - "$out/trivy-report.json" "$(basename "$image")" >"$out/trivy-summary.md" <<'EOF'
import json, sys
from collections import Counter

report = json.load(open(sys.argv[1]))
total, fixable = Counter(), Counter()
for result in report.get("Results") or []:
    for v in result.get("Vulnerabilities") or []:
        sev = v.get("Severity", "UNKNOWN")
        total[sev] += 1
        if v.get("FixedVersion"):
            fixable[sev] += 1

order = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
print(f"### Vulnerability scan: `{sys.argv[2]}`\n")
print("| Severity | Found | Fix available |")
print("|---|---:|---:|")
for sev in order:
    print(f"| {sev} | {total[sev]} | {fixable[sev]} |")
os_info = report.get("Metadata", {}).get("OS", {})
if os_info:
    print(f"\nOS: {os_info.get('Family', '?')} {os_info.get('Name', '?')}. "
          "Report only; the full list is in `trivy-report.json`.")
EOF

cat "$out/trivy-summary.md"
