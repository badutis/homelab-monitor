# homelab-monitor

A ready-to-flash Armbian image that turns a **Makerbase MKS Pi** (Rockchip
RK3328, 1 GB RAM) into a small, self-contained monitoring box for a homelab.

> **Status: pre-release.** The software stack is complete and every build is
> tested in CI; it is being tried on hardware before the first release
> (see [Roadmap](#roadmap)). To try a development build, follow
> [Testing an image on the board](docs/testing-on-hardware.md).

## What is in the image

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
of the card as `homelab.env` and edit it. The example documents every
setting; in short:

| Setting | Required | Applied | Purpose |
|---|---|---|---|
| `HOMELAB_USER` | yes | first boot | login user (key only, passwordless sudo) |
| `HOMELAB_SSH_KEY` | yes, repeatable | first boot | SSH public key(s) of that user |
| `HOSTNAME`, `TIMEZONE` | no | first boot | host name, time zone |
| `DATA_DISK_UUID` | no | first boot | separate disk for the metrics database |
| `GRAFANA_ADMIN_PASSWORD`, `HOMELABLE_ADMIN_PASSWORD` | no | first boot | admin passwords; generated if empty |
| `TARGET` | no, repeatable | `homelabctl apply` | machines to monitor: `<job> <name> <host:port> [<path>]` |
| `LAN_CIDR` | no, repeatable | `homelabctl apply` | networks allowed to reach SSH and the web UI |
| `RETENTION`, `SCRAPE_INTERVAL` | no | `homelabctl apply` | metrics retention, collection interval |
| `GRAFANA_PLUGINS` | no | `homelabctl apply` | extra Grafana datasources to load |
| `HOMELABLE_SCAN_CIDR` | no, repeatable | `homelabctl apply` | networks homelable may scan for devices |

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
`sudo homelabctl report` shows memory use per service, memory pressure and
disks.

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

Done:

- CI builds of the image from pinned sources, with leak, quality,
  vulnerability and image configuration checks.
- VictoriaMetrics, Grafana, node_exporter, first-boot configuration,
  firewall.
- homelable at `/`, network discovery.
- Release workflow with sources and build provenance.

Next:

- Testing on hardware and a week of memory measurements; `v0.1.0-rc.1`.
- `homelabctl update`: update the applications without reflashing.
- Links from homelable nodes to their Grafana dashboards.
- `v1.0.0`.

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
not — and VictoriaMetrics) and a CycloneDX SBOM (`sbom.cdx.json`). CRITICAL and
HIGH findings of `develop` builds also go to the Security tab (code
scanning), with a weekly rebuild. The scan reports; it does not fail the
build yet.

## Releases

Releases are cut from `main` only:

1. `main` is fast-forwarded to a `develop` commit whose leak check, quality
   checks and image build have passed (and that has been tried on a board).
2. Push a tag `vX.Y.Z` (or `vX.Y.Z-rc.N` for a pre-release) on that commit.
3. The release workflow checks the tag is on `main`, rebuilds the image,
   archives the kernel, U-Boot and TF-A sources as built plus the Grafana
   source, writes `SHA256SUMS`, attests build provenance for every asset and
   creates a **draft** GitHub release.
4. Review the draft and publish it.

Each release ships the image (`homelab-monitor-vX.Y.Z-mkspi.img.xz`), its
SBOM, vulnerability report, installed package list, image test results and
the corresponding sources. Verify a download with `sha256sum -c SHA256SUMS`
and `gh attestation verify <file> --repo badutis/homelab-monitor`.

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
  `zizmor` (GitHub Actions security) and the tests below;
- **image build** — when the build inputs change: builds the image, scans it
  and runs `scripts/test-image.sh` against it.

| Tests | What they cover | Where |
|---|---|---|
| `tests/run.sh` | leak check, pinned sources, `homelab.env` parsing and rendering, Grafana plugin list, release notes, scan summary, source archives | anywhere (bash, git, python3) |
| `tests/configs.sh` | firewall rules (`nft -c`), nginx site (`nginx -t`), effective sshd settings (`sshd -T`), YAML/JSON, `homelabctl report` | Linux with sudo (CI) |
| `tests/firstboot.sh` | `homelab-firstboot` and `homelabctl` end to end in Debian trixie | throwaway container (CI) |
| `tests/image-tools.sh` | mounting an image, package list, vulnerability scan, SBOM, SARIF | Linux with sudo (CI) |
| `scripts/test-image.sh` | the built image: SSH, autologin, no baked secrets, services, listen addresses, firewall, packages, ownership, homelable import | every image build |

Run the portable checks locally before pushing:

```bash
LEAK_DENYLIST_FILE=<private word list> scripts/leak-check.sh
tests/run.sh
shellcheck -x -P SCRIPTDIR scripts/*.sh tests/*.sh build/userpatches/*.sh \
  build/userpatches/overlay/rootfs/usr/local/sbin/* build/userpatches/overlay/rootfs/usr/local/lib/homelab/*.sh
shfmt -d scripts tests build && actionlint && zizmor --offline .github/workflows
```

Security issues: see [`SECURITY.md`](SECURITY.md).
