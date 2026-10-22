#!/usr/bin/env bash
# Tests for the image tooling (with-image-rootfs.sh, scan-image.sh) against a
# small synthetic image: a FAT /boot partition and an ext4 root filesystem
# with a Debian 13 os-release and one outdated package.
#
# Linux only; needs sudo, sfdisk, mkfs.vfat, mkfs.ext4, xz and trivy in PATH.
# Runs in CI (quality workflow); not part of tests/run.sh.
#
# Usage: tests/image-tools.sh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
loop=""
cleanup() {
  if mountpoint -q "$tmp/mnt" 2>/dev/null; then sudo umount "$tmp/mnt"; fi
  if [ -n "$loop" ]; then sudo losetup -d "$loop"; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}
pass() { echo "ok   $*"; }

# --- Build the synthetic image -----------------------------------------------

img="$tmp/test.img"
truncate -s 64M "$img"
printf 'label: dos\n,16M,c\n,,83\n' | sfdisk -q "$img"
loop="$(sudo losetup --find --show --partscan "$img")"
sudo udevadm settle || true
sudo mkfs.vfat -n BOOT "${loop}p1" >/dev/null
sudo mkfs.ext4 -q -L rootfs "${loop}p2"

mkdir -p "$tmp/mnt"
sudo mount "${loop}p2" "$tmp/mnt"
sudo mkdir -p "$tmp/mnt/boot" "$tmp/mnt/etc" "$tmp/mnt/var/lib/dpkg"
sudo tee "$tmp/mnt/etc/os-release" >/dev/null <<'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION_CODENAME=trixie
ID=debian
EOF
# Trivy detects Debian from /etc/debian_version, as in the real image.
echo "13.1" | sudo tee "$tmp/mnt/etc/debian_version" >/dev/null
# One installed package at an old version with known vulnerabilities.
sudo tee "$tmp/mnt/var/lib/dpkg/status" >/dev/null <<'EOF'
Package: openssl
Status: install ok installed
Priority: optional
Section: utils
Architecture: arm64
Version: 3.0.0-1
Description: Secure Sockets Layer toolkit

EOF
echo "marker" | sudo tee "$tmp/mnt/etc/marker" >/dev/null
sudo umount "$tmp/mnt"

sudo mount "${loop}p1" "$tmp/mnt"
echo "boot-marker" | sudo tee "$tmp/mnt/bootfile.txt" >/dev/null
sudo umount "$tmp/mnt"
sudo losetup -d "$loop"
loop=""

xz -T0 -1 -k "$img"

# --- with-image-rootfs.sh ----------------------------------------------------

# shellcheck disable=SC2016 # $ROOTFS is expanded by the inner shell
check_mount='test "$(cat "$ROOTFS/etc/marker")" = marker &&
  test "$(cat "$ROOTFS/boot/bootfile.txt")" = boot-marker &&
  ! touch "$ROOTFS/etc/write-test" 2>/dev/null'
"$repo_root/scripts/with-image-rootfs.sh" "$img.xz" bash -c "$check_mount" ||
  fail "with-image-rootfs: root and /boot mounted read-only"
pass "with-image-rootfs: root and /boot mounted read-only"

if "$repo_root/scripts/with-image-rootfs.sh" "$img.xz" false 2>/dev/null; then
  fail "with-image-rootfs: command failure is passed through"
fi
pass "with-image-rootfs: command failure is passed through"

if losetup -a | grep -q "$tmp"; then
  fail "with-image-rootfs: loop devices are detached afterwards"
fi
pass "with-image-rootfs: loop devices are detached afterwards"

# --- scan-image.sh -----------------------------------------------------------

out="$tmp/scan"
"$repo_root/scripts/scan-image.sh" "$img.xz" "$out" >/dev/null
for f in trivy-report.json sbom.cdx.json trivy-summary.md trivy.sarif; do
  [ -s "$out/$f" ] || fail "scan-image: $f written"
done
pass "scan-image: report, SBOM and summary written"

python3 - "$out" <<'EOF' || fail "scan-image: Debian detected and openssl vulnerabilities reported"
import json, sys
out = sys.argv[1]
report = json.load(open(f"{out}/trivy-report.json"))
assert report["Metadata"]["OS"]["Family"] == "debian", report["Metadata"]
vulns = [v for r in report.get("Results") or [] for v in r.get("Vulnerabilities") or []]
assert any(v["PkgName"] == "openssl" for v in vulns), "no openssl findings"
sbom = json.load(open(f"{out}/sbom.cdx.json"))
assert sbom["bomFormat"] == "CycloneDX"
assert any(c.get("name") == "openssl" for c in sbom.get("components", [])), "openssl not in SBOM"
EOF
pass "scan-image: Debian detected and openssl vulnerabilities reported"

python3 - "$out/trivy.sarif" <<'EOF' || fail "scan-image: SARIF has only CRITICAL/HIGH findings"
import json, sys
sarif = json.load(open(sys.argv[1]))
assert sarif["version"] == "2.1.0"
run = sarif["runs"][0]
assert run["results"], "no results"
rules = {r["id"]: r for r in run["tool"]["driver"]["rules"]}
for res in run["results"]:
    tags = rules[res["ruleId"]]["properties"]["tags"]
    assert "CRITICAL" in tags or "HIGH" in tags, (res["ruleId"], tags)
EOF
pass "scan-image: SARIF has only CRITICAL/HIGH findings"

grep -q '| CRITICAL |' "$out/trivy-summary.md" || fail "scan-image: summary table"
pass "scan-image: summary table"
