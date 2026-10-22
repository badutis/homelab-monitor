# userpatches

Copied into the pinned Armbian framework as `userpatches/` before each build
(see `scripts/build-image.sh`). This is Armbian's supported extension point:

- `customize-image.sh` — runs inside the image chroot at the end of the
  build: installs the monitoring stack and our files, enables the services.
- `overlay/` — available in the chroot as `/tmp/overlay` (read-only):
  - `rootfs/` — files copied as-is into `/` (configuration, systemd units,
    `homelabctl`, `homelab-firstboot`, the Grafana dashboard);
  - `downloads/` — release artifacts from `sources.lock`, fetched and
    SHA256-checked by `scripts/build-image.sh` (not in git);
  - `README.image` — installed as `/usr/share/doc/homelab-monitor/README`.
