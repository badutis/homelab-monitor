# homelab-monitor

A ready-to-flash Armbian image that turns a **Makerbase MKS Pi** (Rockchip
RK3328, 1 GB RAM) into a small, self-contained monitoring box for a homelab.

> **Status: early work in progress.** No image has been released yet. The
> repository is being built up step by step (see [Roadmap](#roadmap)).

## What will be in the image

| Component | Source | Notes |
|---|---|---|
| Armbian Debian Trixie minimal, kernel `current` | [`redrathnure/armbian-mkspi`](https://github.com/redrathnure/armbian-mkspi), built from source | kernel and u-boot frozen (`BSPFREEZE=yes`) |
| [homelable](https://github.com/Pouzor/homelable) | pinned tag, no Docker | Python venv + systemd + nginx; the web UI is built in CI, not on the board |
| [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics) single-node | official `linux-arm64` release | metrics storage, on a separate data disk |
| [Grafana OSS](https://github.com/grafana/grafana) | official apt repository, pinned | dashboards and alerts |
| `prometheus-node-exporter` | Debian package | board metrics and sensors via `hwmon` |
| homelab-monitor glue | this repository | first-boot setup, scrape config generator, dashboards, firewall |

Hardware features on the MKS Pi GPIO header — DS18B20 1-Wire temperature
sensors and fan control — are planned for a later stage, after `v1.0.0`.

## Configuration

The image contains **no addresses, keys or host names**. After flashing, you
create `homelab.env` on the FAT `/boot` partition (an example file will be
provided as `homelab.env.example`). On first boot it is moved to
`/etc/homelab/` and removed from `/boot`.

Examples in this repository use only documentation addresses
(`192.0.2.0/24`, `198.51.100.0/24`) and `example.invalid`.

## Roadmap

0. Repository skeleton, pinned sources, leak-check CI.
1. CI build of a plain Armbian Trixie minimal image from `sources.lock`.
2. VictoriaMetrics, Grafana, node_exporter, first-boot service.
3. homelable.
4. `homelabctl update`, release source archives, `v1.0.0`.

Later: hardware stage — DS18B20 sensors and fan control on the GPIO header.

## Building

Images are built from source on GitHub-hosted Linux runners
(`.github/workflows/build-image.yml`): kernel, u-boot and rootfs are compiled
from the pinned Armbian framework, never downloaded from the Armbian artifact
cache. To build locally on an Ubuntu 24.04 machine (sudo, ~40 GB free disk):

```bash
scripts/build-image.sh
```

Outputs land in `.work/out/`: the `.img.xz` image and its checksum, the source
archive of the pinned framework, build logs and `BUILD-INFO.txt`.

## Pinned sources

Upstream components are pinned in [`sources.lock`](sources.lock) by tag **and**
commit; the build fails if a tag no longer points to the recorded commit.

## Sources and licenses

This repository's build code is licensed under **GPL-2.0** (see
[`LICENSE`](LICENSE)), because it runs inside the GPL-2.0 Armbian build
framework.

Released images contain third-party software under their own licenses
(GPL-2.0, MIT, AGPL-3.0, Apache-2.0 and others). See
[`THIRD_PARTY.md`](THIRD_PARTY.md). Each release will ship the corresponding
source archives (Armbian/kernel/u-boot, Grafana) next to the image.

## Contributing

Branches:

- `develop` — default branch; every change lands here through a pull request
  with a green leak check.
- `main` — released, verified code only. It moves forward (fast-forward only)
  to a `develop` commit whose leak check **and** image build have passed.

Every pull request runs:

- **leak check** — `gitleaks` plus a scan of files, commit messages and PR text
  for private IPv4 ranges, MAC addresses and internal host names;
- **quality** — `shellcheck`, `shfmt` (style in `.editorconfig`), `actionlint`,
  `zizmor` (GitHub Actions security) and the script tests;
- **image build** — when the build inputs change.

Run the same checks locally before pushing:

```bash
scripts/leak-check.sh
tests/run.sh
shellcheck -x scripts/*.sh tests/*.sh && shfmt -d scripts tests && actionlint && zizmor --offline .github/workflows
```

Security issues: see [`SECURITY.md`](SECURITY.md).
