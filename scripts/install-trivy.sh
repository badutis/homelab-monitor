#!/usr/bin/env bash
# Install the pinned Trivy release into /usr/local/bin (Linux x86_64, sudo).
#
# The release checksum file was verified with cosign when pinning (signed by
# the aquasecurity/trivy release workflow); here the tarball is checked
# against that SHA256. Versions affected by the March 2026 supply-chain
# incident (GHSA-69fq-xp46-6x23) must never be pinned.

set -euo pipefail

TRIVY_VERSION=0.75.0
TRIVY_SHA256=c6e65abddb348e25f10549df887045629cf28cc72453cd1c63acb717316b3f3f

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
f="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
curl -fsSL -o "$tmp/$f" "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/$f"
echo "${TRIVY_SHA256}  $tmp/$f" | sha256sum -c -
tar -xzf "$tmp/$f" -C "$tmp" trivy
sudo install -m 0755 "$tmp/trivy" /usr/local/bin/trivy
trivy --version
