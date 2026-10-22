#!/usr/bin/env bash
# Runs inside the image chroot at the end of the Armbian build (Armbian
# userpatches hook). Installs the monitoring stack and our configuration.
#
# Inputs, prepared by scripts/build-image.sh in /tmp/overlay:
#   downloads/   release artifacts verified against sources.lock
#   rootfs/      files copied as-is into /
#   homelable    built by scripts/build-homelable.sh (in downloads/)
#
# Arguments from Armbian: RELEASE LINUXFAMILY BOARD BUILD_DESKTOP ARCH

set -euo pipefail

OVERLAY=/tmp/overlay
DL="$OVERLAY/downloads"
export DEBIAN_FRONTEND=noninteractive

log() { echo "[homelab-monitor] $*"; }

log "installing packages"
apt-get update
apt-get install -y --no-install-recommends \
  prometheus-node-exporter nginx nftables sudo ca-certificates \
  unattended-upgrades apt-listchanges \
  python3 python3-venv iputils-ping nmap

log "installing Grafana $(basename "$DL"/grafana_*_arm64.deb)"
apt-get install -y --no-install-recommends "$DL"/grafana_*_arm64.deb
apt-mark hold grafana

log "installing VictoriaMetrics"
tar -xzf "$DL"/victoria-metrics-linux-arm64-*.tar.gz -C /usr/local/bin victoria-metrics-prod
chown root:root /usr/local/bin/victoria-metrics-prod
chmod 0755 /usr/local/bin/victoria-metrics-prod
install -D -m 0644 "$DL/LICENSE" /usr/share/doc/victoria-metrics/LICENSE
if ! id victoriametrics >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /var/lib/victoria-metrics \
    --shell /usr/sbin/nologin victoriametrics
fi
install -d -o victoriametrics -g victoriametrics -m 0750 /var/lib/victoria-metrics

log "installing homelable $(tar -xzOf "$DL/homelable-backend.tar.gz" VERSION)"
if ! id homelable >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /var/lib/homelable \
    --shell /usr/sbin/nologin homelable
fi
install -d -o homelable -g homelable -m 0750 /var/lib/homelable
install -d -m 0755 /opt/homelable /opt/homelable/frontend
tar -xzf "$DL/homelable-backend.tar.gz" -C /opt/homelable --no-same-owner
tar -xzf "$DL/homelable-frontend.tar.gz" -C /opt/homelable/frontend --no-same-owner
# Python dependencies: every package pinned by SHA256, wheels only; the one
# source-only package (python-nmap, pure Python) is built with the pinned
# setuptools without fetching anything else.
python3 -m venv /opt/homelable/venv
pip=(/opt/homelable/venv/bin/pip install --no-cache-dir --disable-pip-version-check --require-hashes)
"${pip[@]}" --only-binary :all: -r "$DL/build-requirements.lock"
"${pip[@]}" --only-binary :all: --no-binary python-nmap --no-build-isolation -r "$DL/requirements.lock"
/opt/homelable/venv/bin/python -m compileall -q /opt/homelable/backend/app
chown -R root:root /opt/homelable
chmod -R go-w /opt/homelable
install -D -m 0644 /opt/homelable/LICENSE /usr/share/doc/homelable/LICENSE
install -m 0644 "$DL/homelable-frontend-licenses.txt" /usr/share/doc/homelable/frontend-licenses.txt
/opt/homelable/venv/bin/python - >/usr/share/doc/homelable/python-licenses.txt <<'PY'
from importlib.metadata import distributions
print("# Python packages in /opt/homelable/venv: name version license")
for d in sorted(distributions(), key=lambda d: d.metadata["Name"].lower()):
    m = d.metadata
    lic = m.get("License-Expression") or m.get("License") or ""
    if not lic or len(lic) > 60:
        lic = "; ".join(c.split(" :: ")[-1] for c in m.get_all("Classifier") or [] if c.startswith("License ::")) or "see package"
    print(f"{m['Name']} {d.version} {lic}")
PY

log "installing homelab-monitor files"
# Files are owned by the CI user in the checkout; install them as root.
cp -r --no-preserve=ownership "$OVERLAY/rootfs/." /
chown -R root:root /etc/homelab /etc/victoria-metrics /usr/local/lib/homelab \
  /usr/local/sbin/homelabctl /usr/local/sbin/homelab-firstboot /usr/share/homelab
chmod 0700 /etc/homelab
chmod 0600 /etc/homelab/nftables-lan.nft
chmod 0755 /usr/local/sbin/homelabctl /usr/local/sbin/homelab-firstboot
chmod 0644 /usr/local/lib/homelab/homelab.sh
install -d -m 0755 /usr/share/doc/homelab-monitor
cp "$OVERLAY/README.image" /usr/share/doc/homelab-monitor/README

# Grafana bundled plugins: list what the package ships (directory name =
# plugin id, checked against plugin.json), load only the prometheus
# datasource by default, and drop the writable copy the package makes in
# /var/lib/grafana for auto-updates (we use the packaged copy, see the
# grafana-server drop-in).
bundled=/usr/share/grafana/data/plugins-bundled
: >/usr/share/homelab/grafana-bundled-plugins
for dir in "$bundled"/*/; do
  id="$(basename "$dir")"
  grep -qE "^[[:space:]]*\"id\":[[:space:]]*\"$id\"" "$dir/plugin.json" ||
    {
      echo "plugin id in $dir/plugin.json is not $id" >&2
      exit 1
    }
  echo "$id" >>/usr/share/homelab/grafana-bundled-plugins
done
grep -qx prometheus /usr/share/homelab/grafana-bundled-plugins
# shellcheck source=overlay/rootfs/usr/local/lib/homelab/homelab.sh
source /usr/local/lib/homelab/homelab.sh
hl_reset
hl_render_grafana_plugins /usr/share/homelab/grafana-bundled-plugins >/etc/grafana/homelab-plugins.env
chmod 0644 /etc/grafana/homelab-plugins.env
rm -rf /var/lib/grafana/plugins-bundled

# nginx: our site only.
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/homelab /etc/nginx/sites-enabled/homelab

# SSH: key only, no root (drop-in in sshd_config.d); also fix Armbian's
# PermitRootLogin yes in the main file so nothing contradicts the drop-in.
sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
grep -qE '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config ||
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config

# Console: no automatic root login (Armbian enables it by default).
rm -f /etc/systemd/system/getty@.service.d/override.conf \
  /etc/systemd/system/serial-getty@.service.d/override.conf

# Security updates only, applied automatically (Debian default origins).
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

log "enabling services"
systemctl enable homelab-firstboot.service victoria-metrics.service \
  grafana-server.service homelable.service nginx.service nftables.service \
  prometheus-node-exporter.service unattended-upgrades.service

# Grafana writes its own database on first start; make sure the build left
# none behind (it would have been created without our admin password).
rm -f /var/lib/grafana/grafana.db

apt-get clean
log "done"
