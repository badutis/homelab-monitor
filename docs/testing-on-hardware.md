# Testing an image on the board

How to flash a build onto a Makerbase MKS Pi, check that everything works and
measure memory use. Use it for development builds before a release, and to
report problems.

## 1. Get an image

- **Release**: download `homelab-monitor-vX.Y.Z-mkspi.img.xz` and
  `SHA256SUMS` from the [releases](https://github.com/badutis/homelab-monitor/releases),
  then `sha256sum -c SHA256SUMS --ignore-missing`.
- **Development build**: Actions → `build-image` → the latest successful run
  on `develop` → artifact `homelab-monitor-image-<commit>`. With the GitHub CLI:

  ```bash
  gh run download --repo badutis/homelab-monitor -n homelab-monitor-image-<commit>
  ```

  The artifact contains the `.img.xz`, `BUILD-INFO.txt` (exact commit and
  build settings) and the scan and test results of that build.

## 2. Flash

Write the `.img.xz` to a microSD card (8 GB or more) with
[balenaEtcher](https://etcher.balena.io/) or Raspberry Pi Imager ("use
custom"); both read `.xz` directly. On Linux:

```bash
xzcat homelab-monitor-*.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

## 3. Configure

After flashing, the card's small FAT partition shows up as a separate disk on
macOS, Windows and Linux. Copy [`homelab.env.example`](../homelab.env.example)
to it as `homelab.env` and set at least:

- `HOMELAB_USER` and `HOMELAB_SSH_KEY` (your public key, e.g. the content of
  `~/.ssh/id_ed25519.pub`);
- a few `TARGET=` lines for machines that run node_exporter;
- `TIMEZONE`, optionally `HOMELABLE_SCAN_CIDR` for device discovery.

**Metrics disk (recommended).** To keep the database off the SD card, put an
ext4-formatted USB disk's UUID (`blkid`) into `DATA_DISK_UUID` before the
first boot. The disk is set up on the first boot only; to add one later,
copy `homelab.env` (with the UUID) to the boot partition again and reboot.

## 4. First boot

Insert the card, connect Ethernet, power on. The first boot resizes the
filesystem and applies `homelab.env`; give it 3–5 minutes. Find the board's
address in your router's DHCP list.

If `homelab.env` had a mistake, nothing was applied: put the card back into
your computer and read `homelab.env.error` on the FAT partition, fix
`homelab.env` and boot again. `homelab.env.applied` means it worked.

## 5. Checklist

| Check | How | Expected |
|---|---|---|
| SSH with your key | `ssh <user>@<address>` | logs in; no password asked |
| No password logins | `ssh -o PubkeyAuthentication=no <user>@<address>` | `Permission denied (publickey)` |
| Services | `systemctl --failed` | `0 loaded units listed` |
| Settings | `sudo homelabctl check` | `ok: N target(s), …` |
| Version | `cat /usr/share/homelab/VERSION` | the build you flashed |
| homelable | `http://<address>/` | login page; `admin` + your or the generated password (`sudo cat /root/homelab-credentials.txt`) |
| Grafana | `http://<address>/grafana/` | dark login page; dashboard "Homelab overview" lists this box and your targets |
| Targets up | Grafana → Homelab overview → "Targets" | every `TARGET` shows UP within a minute |
| Status checks | homelable: add a node with ping check | turns online |
| Discovery (if `HOMELABLE_SCAN_CIDR` set) | homelable → scan | finds devices |
| Firewall | from a network outside `LAN_CIDR` | SSH and HTTP do not answer |
| Change settings | edit `/etc/homelab/homelab.env` (sudo), `sudo homelabctl apply` | prints what was restarted |

## 6. Measure memory

The board has 1 GB; this decides whether everything fits. Run once a day for
a week, with the usual targets configured:

```bash
sudo homelabctl report | tee "report-$(date +%F).txt"
```

It prints total and available memory, memory pressure, each service's current
and peak memory since start, Grafana plugin processes, the largest processes,
disk use and out-of-memory kills. Signs of trouble: `full` memory pressure
above zero, out-of-memory kills, or services restarting.

## Reporting a problem

Open an issue with the board revision, the image version
(`/usr/share/homelab/VERSION`), what you did and what happened, plus the
output of `sudo homelabctl report` and `journalctl -b -u <service>` for the
service in question. Leave out `homelab.env` and anything with addresses,
keys or passwords.
