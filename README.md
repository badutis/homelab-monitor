# homelab-monitor

A ready-to-flash Armbian image that turns a **Makerbase MKS Pi** (Rockchip
RK3328, 1 GB RAM) into a small, self-contained monitoring box for a homelab.

> **Status: early work in progress.** No image has been released yet. The
> repository is being built up step by step (see [Roadmap](#roadmap)).

## What will be in the image

| Component | Source | Notes |
|---|---|---|
| Armbian Debian Trixie minimal, kernel `current` | [`redrathnure/armbian-mkspi`](https://github.com/redrathnure/armbian-mkspi), built from source | kernel and u-boot frozen (`BSPFREEZE=yes`) |
| [homelable](https://github.com/Pouzor/homelable) | pinned tag, no Docker | homelab map at `/`; backend in a Python venv (`127.0.0.1:8000`, every dependency SHA256-pinned), web UI built in CI; network discovery with nmap for the networks in `HOMELABLE_SCAN_CIDR` |
| [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics) single-node | official `linux-arm64` release, SHA256-pinned | metrics storage, `127.0.0.1:8428`; data ideally on a separate disk |
| [Grafana OSS](https://github.com/grafana/grafana) | official `arm64` package, SHA256-pinned, held | dashboards and alerts at `/grafana/`, dark theme, no plugin downloads or telemetry; only the Prometheus datasource is loaded by default, other bundled datasources via `GRAFANA_PLUGINS` |
| `prometheus-node-exporter` | Debian package | metrics of this box, `127.0.0.1:9100` |
| nginx, nftables | Debian packages | single entry point on port 80 (`/` homelable, `/grafana/` Grafana); inbound SSH/HTTP from the LAN only |
| homelab-monitor glue | this repository | first-boot setup, scrape config generator, dashboards, firewall |

Hardware features on the MKS Pi GPIO header — DS18B20 1-Wire temperature
sensors and fan control — are planned for a later stage, after `v1.0.0`.

## Configuration

The image contains **no addresses, keys or host names**. After flashing,
copy [`homelab.env.example`](homelab.env.example) to the FAT boot partition
of the card as `homelab.env` and edit it (login user, SSH key, machines to
monitor, optional data disk and time zone).

On the first boot that finds it, `homelab-firstboot`:

1. validates the file — it is parsed, never executed; unknown keys or bad
   values stop everything and the reasons are written to
   `homelab.env.error` on the same partition;
2. creates the user with the SSH key(s), locks all passwords (root included);
3. sets host name, time zone and the metrics disk;
4. generates the scrape configuration and firewall networks;
5. moves the settings to `/etc/homelab/homelab.env` (root only) and deletes
   `homelab.env` from the card.

Later changes: edit `/etc/homelab/homelab.env`, then `sudo homelabctl apply`.

Open `http://<box>/` for the homelable map and `http://<box>/grafana/` for
the dashboards. Both log in as `admin` with the passwords from `homelab.env`
(`HOMELABLE_ADMIN_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`) or generated ones in
`/root/homelab-credentials.txt`. Until the first boot has run, both addresses
show a "not configured" page.

### Security model

- SSH: public key only, no root login, no passwords.
- Console: no automatic login. Without `homelab.env` the only way in is the
  console as root with Armbian's initial password `1234`, which must be
  changed at once; SSH stays closed until a key is configured.
- Web UIs: Grafana and homelable start only after the first boot has set
  their admin passwords and secret key — never with upstream defaults
  (`admin`/`admin`).
- Network: Grafana, homelable, VictoriaMetrics and node_exporter listen on localhost;
  nginx on port 80 and SSH accept connections only from the networks in
  `LAN_CIDR` (default: private ranges).
- Updates: Debian security updates install automatically; kernel and
  u-boot change only with a new image.

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

CI also scans every built image with [Trivy](https://github.com/aquasecurity/trivy)
(`scripts/scan-image.sh`): a vulnerability report for the installed Debian
packages and the bundled binaries (`trivy-report.json`; the job summary
breaks it down by source: Debian, Grafana, its bundled plugins — loaded or
not — and VictoriaMetrics) and a CycloneDX SBOM (`sbom.cdx.json`). The scan
reports; it does not fail the build yet.

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
