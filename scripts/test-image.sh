#!/usr/bin/env bash
# Configuration tests for a built image, run against its mounted root
# filesystem (see scripts/with-image-rootfs.sh):
#
#   scripts/with-image-rootfs.sh image.img.xz scripts/test-image.sh
#
# Checks what the image promises before anyone flashes it: SSH is key-only
# with no root login, no console autologin, services listen where they
# should, the firewall drops by default, the stack is installed and enabled,
# our files are root-owned, and no configuration or secrets are baked in.
# Reads root-only files with sudo.

set -euo pipefail

root="${ROOTFS:?run through scripts/with-image-rootfs.sh}"
failed=0
passed=0

ok() {
  echo "ok   $1"
  passed=$((passed + 1))
}
bad() {
  echo "FAIL $1"
  failed=$((failed + 1))
}
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
has_line() { sudo grep -qE "$2" "$root/$1"; }
no_line() { ! sudo grep -qE "$2" "$root/$1"; }
exists() { sudo test -e "$root/$1"; }
absent() { ! sudo test -e "$root/$1"; }
enabled() { sudo find "$root/etc/systemd/system" -path "*.wants/$1" | grep -q .; }
owned_by_root() { [ -z "$(sudo find "$root/$1" ! -uid 0 -print -quit)" ]; }
mode_is() { [ "$(sudo stat -c '%a' "$root/$1")" = "$2" ]; }

# --- SSH -----------------------------------------------------------------------
d=etc/ssh/sshd_config.d/10-homelab.conf
check "ssh: root login disabled" has_line "$d" '^PermitRootLogin no$'
check "ssh: password login disabled" has_line "$d" '^PasswordAuthentication no$'
check "ssh: keyboard-interactive disabled" has_line "$d" '^KbdInteractiveAuthentication no$'
check "ssh: drop-ins included by sshd_config" has_line etc/ssh/sshd_config '^Include /etc/ssh/sshd_config.d/\*\.conf'
check "ssh: main config does not allow root login" no_line etc/ssh/sshd_config '^PermitRootLogin (yes|prohibit-password)'

# --- Console -----------------------------------------------------------------
no_autologin() {
  ! sudo grep -rqs -- '--autologin' "$root/etc/systemd/system/getty@.service.d" \
    "$root/etc/systemd/system/serial-getty@.service.d"
}
check "console: no automatic root login" no_autologin

# --- No configuration or secrets baked into the image ----------------------
for f in boot/homelab.env etc/homelab/homelab.env etc/homelab/grafana-admin.env \
  root/homelab-credentials.txt var/lib/grafana/grafana.db; do
  check "no baked file: /$f" absent "$f"
done
check "secrets dir /etc/homelab is 0700" mode_is etc/homelab 700
check "firewall networks file is 0600" mode_is etc/homelab/nftables-lan.nft 600

# --- Services ------------------------------------------------------------------
for unit in homelab-firstboot.service victoria-metrics.service grafana-server.service \
  nginx.service nftables.service prometheus-node-exporter.service ssh.service \
  unattended-upgrades.service; do
  check "enabled: $unit" enabled "$unit"
done
check "first boot runs only with /boot/homelab.env" \
  has_line etc/systemd/system/homelab-firstboot.service '^ConditionPathExists=/boot/homelab.env$'
check "first boot runs before SSH and the web services" \
  has_line etc/systemd/system/homelab-firstboot.service '^Before=.*ssh\.service.*grafana-server\.service'

# --- Listening addresses -------------------------------------------------------
check "victoria-metrics on localhost" has_line etc/systemd/system/victoria-metrics.service 'httpListenAddr=127\.0\.0\.1:8428'
check "grafana on localhost" has_line etc/systemd/system/grafana-server.service.d/homelab.conf '^Environment=GF_SERVER_HTTP_ADDR=127\.0\.0\.1$'
check "node_exporter on localhost" has_line etc/default/prometheus-node-exporter 'web\.listen-address=127\.0\.0\.1:9100'
check "nginx: only our site enabled" bash -c "[ \"\$(sudo ls '$root/etc/nginx/sites-enabled')\" = homelab ]"
check "grafana: no plugin downloads at start" has_line etc/systemd/system/grafana-server.service.d/homelab.conf '^Environment=GF_PLUGINS_PREINSTALL_DISABLED=true$'
check "grafana: no anonymous access" has_line etc/systemd/system/grafana-server.service.d/homelab.conf '^Environment=GF_AUTH_ANONYMOUS_ENABLED=false$'
check "grafana: packaged read-only bundled plugins" has_line etc/systemd/system/grafana-server.service.d/homelab.conf '^Environment=GF_PATHS_BUNDLED_PLUGINS=/usr/share/grafana/data/plugins-bundled$'
check "grafana: no plugin auto-updates" has_line etc/systemd/system/grafana-server.service.d/homelab.conf '^Environment=GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false$'
check "grafana: no writable copy of bundled plugins" absent var/lib/grafana/plugins-bundled
check "grafana: bundled plugin list includes prometheus" has_line usr/share/homelab/grafana-bundled-plugins '^prometheus$'
check "grafana: unused plugins disabled by default" has_line etc/grafana/homelab-plugins.env '^GF_PLUGINS_DISABLE_PLUGINS=.*loki'
check "grafana: prometheus datasource not disabled" \
  bash -c "! sudo grep -E '^GF_PLUGINS_DISABLE_PLUGINS=(.*,)?prometheus(,|\$)' '$root/etc/grafana/homelab-plugins.env'"

# --- Firewall ------------------------------------------------------------------
check "firewall: inbound policy drop" has_line etc/nftables.conf 'type filter hook input priority filter; policy drop;'
# shellcheck disable=SC2016 # $LAN_V4 is literal text in nftables.conf
check "firewall: SSH/HTTP only from LAN sets" has_line etc/nftables.conf 'ip saddr \$LAN_V4 tcp dport \{ 22, 80 \} accept'

# --- Installed software --------------------------------------------------------
check "victoria-metrics binary is arm64" bash -c "file -b '$root/usr/local/bin/victoria-metrics-prod' | grep -q 'ARM aarch64'"
check "grafana installed" exists usr/share/grafana/bin/grafana
check "grafana held at the pinned version" \
  bash -c "sudo awk '/^Package: grafana\$/{p=1} p&&/^Status:/{print; exit}' '$root/var/lib/dpkg/status' | grep -q '^Status: hold ok installed'"
check "node_exporter installed" exists usr/bin/prometheus-node-exporter
check "nftables installed" exists usr/sbin/nft
check "license: VictoriaMetrics" exists usr/share/doc/victoria-metrics/LICENSE
check "license: Grafana" exists usr/share/grafana/LICENSE
check "dashboard provisioned" exists usr/share/homelab/dashboards/homelab-overview.json
check "datasource provisioned" exists etc/grafana/provisioning/datasources/homelab.yaml

# --- Ownership of our files ----------------------------------------------------
for p in etc/homelab etc/victoria-metrics etc/ssh/sshd_config.d/10-homelab.conf \
  etc/nftables.conf etc/nginx/sites-available/homelab etc/systemd/system/victoria-metrics.service \
  etc/systemd/system/homelab-firstboot.service etc/systemd/system/grafana-server.service.d \
  etc/grafana/provisioning/datasources/homelab.yaml usr/local/sbin/homelabctl \
  usr/local/sbin/homelab-firstboot usr/local/lib/homelab usr/share/homelab; do
  check "owned by root: /$p" owned_by_root "$p"
done
check "homelabctl executable" bash -c "sudo test -x '$root/usr/local/sbin/homelabctl'"
check "homelab-firstboot executable" bash -c "sudo test -x '$root/usr/local/sbin/homelab-firstboot'"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
