# Third-party software

The homelab-monitor image is assembled from the components below. Each keeps
its own license. Exact versions are recorded in [`sources.lock`](sources.lock)
and in each release's package list.

| Component | License | Copyright / upstream | How we comply |
|---|---|---|---|
| Armbian build framework and `armbian-mkspi` patches | GPL-2.0 | [armbian/build](https://github.com/armbian/build), [redrathnure/armbian-mkspi](https://github.com/redrathnure/armbian-mkspi) | our build code is GPL-2.0; every release ships the `armbian-mkspi` source archive at the pinned tag, the kernel source package, the u-boot commit and the build log |
| Linux kernel | GPL-2.0 | [kernel.org](https://www.kernel.org/) | source package attached to the same release |
| U-Boot | GPL-2.0+ | [u-boot](https://source.denx.de/u-boot/u-boot) | source reference and archive attached to the same release |
| homelable | MIT, © 2026 Remy Jardinet | [Pouzor/homelable](https://github.com/Pouzor/homelable) | `LICENSE`, the npm packages bundled into the web UI and the Python packages of its venv, each with version and license, installed to `/usr/share/doc/homelable/` |
| nmap | NPSL (Nmap Public Source License) | [nmap.org](https://nmap.org/) | unmodified Debian package, for homelable's network discovery; license text in `/usr/share/doc/nmap/copyright`. The image is free and open source and is not sold with any product |
| Grafana OSS | AGPL-3.0 | [grafana/grafana](https://github.com/grafana/grafana) | source archive of the shipped version attached to each release |
| VictoriaMetrics | Apache-2.0 | [VictoriaMetrics/VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics) | `LICENSE` and `NOTICE` installed in the image |
| Debian packages | various (see each package's `/usr/share/doc/*/copyright`) | [debian.org](https://www.debian.org/) | each release ships a `dpkg-query` package list with versions; sources are available from [snapshot.debian.org](https://snapshot.debian.org/) |

Components are added to the image step by step; this table lists everything
that is planned. A component appears in a release only once its step is merged.
