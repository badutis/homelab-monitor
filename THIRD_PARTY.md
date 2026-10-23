# Third-party software

The homelab-monitor image is assembled from the components below. Each keeps
its own license. Exact versions are recorded in [`sources.lock`](sources.lock)
and in each release's package list.

| Component | License | Copyright / upstream | How we comply |
|---|---|---|---|
| Armbian build framework and `armbian-mkspi` patches | GPL-2.0 | [armbian/build](https://github.com/armbian/build), [redrathnure/armbian-mkspi](https://github.com/redrathnure/armbian-mkspi) | our build code is GPL-2.0; every release ships the `armbian-mkspi` source archive at the pinned tag |
| Linux kernel | GPL-2.0 | [kernel.org](https://www.kernel.org/) | source archive as built (Armbian patches applied, with the kernel `.config`) attached to the same release |
| U-Boot | GPL-2.0+ | [u-boot](https://source.denx.de/u-boot/u-boot) | source archive (as built, Armbian patches applied) attached to the same release |
| Trusted Firmware-A | BSD-3-Clause | [TF-A](https://www.trustedfirmware.org/projects/tf-a/) | source archive attached to the same release |
| Rockchip boot blobs (rkbin) | Rockchip binary license | [rockchip-linux/rkbin](https://github.com/rockchip-linux/rkbin) | binary only, as in every Armbian image for RK3328 |
| homelable | MIT, © 2026 Remy Jardinet | [Pouzor/homelable](https://github.com/Pouzor/homelable) | `LICENSE`, the npm packages bundled into the web UI and the Python packages of its venv, each with version and license, installed to `/usr/share/doc/homelable/` |
| nmap | NPSL (Nmap Public Source License) | [nmap.org](https://nmap.org/) | unmodified Debian package, for homelable's network discovery; license text in `/usr/share/doc/nmap/copyright`. The image is free and open source and is not sold with any product |
| Grafana OSS | AGPL-3.0 | [grafana/grafana](https://github.com/grafana/grafana) | source archive of the shipped version attached to each release |
| VictoriaMetrics | Apache-2.0 | [VictoriaMetrics/VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics) | `LICENSE` installed to `/usr/share/doc/victoria-metrics/` (upstream ships no `NOTICE` file) |
| Debian packages | various (see each package's `/usr/share/doc/*/copyright`) | [debian.org](https://www.debian.org/) | each release ships `packages.tsv` with package and source versions; the sources are on [snapshot.debian.org](https://snapshot.debian.org/) |

Release assets with the corresponding sources are described in each release's
notes and in `SOURCES.txt`.
