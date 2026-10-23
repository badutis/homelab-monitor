#!/usr/bin/env bash
# Integration test of homelab-firstboot and homelabctl in Debian trixie, the
# image's base, run as root inside a throwaway container (CI):
#
#   docker run --rm --cap-add NET_ADMIN --cap-add SYS_ADMIN \
#     -v "$PWD:/src:ro" debian:trixie /src/tests/firstboot.sh /src
#
# NET_ADMIN lets "nft -c" check the firewall rules, SYS_ADMIN lets the first
# boot set the host name. Never run this on a real system: it creates users,
# locks root and rewrites /etc.

# shellcheck disable=SC2016 # bash -c '...' snippets expand in the inner shell
set -euo pipefail

src="${1:-/src}"
rootfs="$src/build/userpatches/overlay/rootfs"
[ -f /.dockerenv ] || [ "${HOMELAB_TEST_CONTAINER:-0}" = 1 ] || {
  echo "refusing to run outside a container" >&2
  exit 1
}

passed=0
failed=0
ok() {
  echo "ok   $1"
  passed=$((passed + 1))
}
bad() {
  echo "FAIL $1"
  failed=$((failed + 1))
}
check() {
  local desc="$1" out
  shift
  if out="$("$@" 2>&1)"; then ok "$desc"; else
    bad "$desc"
    [ -z "$out" ] || printf '%s\n' "$out" | tail -n 15 | sed 's/^/     | /'
  fi
}
mode_is() { [ "$(stat -c '%a' "$1")" = "$2" ]; }
owner_is() { [ "$(stat -c '%U' "$1")" = "$2" ]; }
locked() { [ "$(passwd -S "$1" | awk '{print $2}')" = L ]; }
has() { grep -qE -e "$2" "$1"; }
field() { sed -n "s/^$2=//p" "$1"; }

# --- Prepare a system like the image (see customize-image.sh) ---------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  sudo passwd nftables python3 python3-bcrypt tzdata ca-certificates >/dev/null
cp -r --no-preserve=ownership "$rootfs/." /
chmod 0755 /usr/local/sbin/homelabctl /usr/local/sbin/homelab-firstboot
chmod 0700 /etc/homelab
chmod 0600 /etc/homelab/nftables-lan.nft
useradd --system --no-create-home --home-dir /var/lib/victoria-metrics \
  --shell /usr/sbin/nologin victoriametrics
# homelable's venv: only its Python (with bcrypt) is used by the first boot.
mkdir -p /opt/homelable/venv/bin /boot /etc/grafana
ln -sf /usr/bin/python3 /opt/homelable/venv/bin/python
printf '%s\n' loki mysql prometheus tempo >/usr/share/homelab/grafana-bundled-plugins
touch /root/.not_logged_in_yet

key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFirstBootTestKeyOnly0000000000000000000000 t@example.invalid"

# --- 1. Invalid homelab.env: nothing is applied ------------------------------
cat >/boot/homelab.env <<EOF
HOMELAB_USER=root
HOMELAB_SSH_KEY="$key"
TARGET=node a 192.0.2.1:99999
EOF
check "invalid env: first boot fails" bash -c '! /usr/local/sbin/homelab-firstboot'
check "invalid env: reasons written to the boot partition" has /boot/homelab.env.error "reserved system account"
check "invalid env: reasons include every error" has /boot/homelab.env.error "port 1-65535"
check "invalid env: file stays on the card" test -f /boot/homelab.env
check "invalid env: no settings installed" test ! -e /etc/homelab/homelab.env
check "invalid env: not marked configured" test ! -e /var/lib/homelab-monitor/configured

# --- 2. Valid homelab.env -----------------------------------------------------
cat >/boot/homelab.env <<EOF
# test configuration
HOMELAB_USER=admin
HOMELAB_SSH_KEY="$key"
HOSTNAME=monitor-test
TIMEZONE=Europe/Vilnius
HOMELABLE_ADMIN_PASSWORD=Test-password-123
GRAFANA_PLUGINS=loki
HOMELABLE_SCAN_CIDR=192.0.2.0/24
TARGET=node server-1 192.0.2.10:9100
EOF
cp /boot/homelab.env /tmp/expected.env
check "valid env: first boot succeeds" /usr/local/sbin/homelab-firstboot
check "card: homelab.env deleted" test ! -e /boot/homelab.env
check "card: old error report removed" test ! -e /boot/homelab.env.error
check "card: applied note written" test -f /boot/homelab.env.applied
check "configured marker for nginx" test -f /var/lib/homelab-monitor/configured

check "user: created" id admin
check "user: in sudo group" bash -c 'id -nG admin | grep -qw sudo'
check "user: password locked (key only)" locked admin
check "user: authorized_keys has the key" bash -c "[ \"\$(cat ~admin/.ssh/authorized_keys)\" = '$key' ]"
check "user: authorized_keys 0600, owned by the user" bash -c 'f=~admin/.ssh/authorized_keys; [ "$(stat -c %a:%U "$f")" = 600:admin ]'
check "user: .ssh 0700" mode_is /home/admin/.ssh 700
check "sudo: rule installed 0440" mode_is /etc/sudoers.d/90-homelab-admin 440
check "sudo: passwordless rule" has /etc/sudoers.d/90-homelab-admin '^admin ALL=\(ALL\) NOPASSWD:ALL$'
check "sudo: configuration valid" visudo -cq
check "root: password locked" locked root
check "root: Armbian first-login prompt removed" test ! -e /root/.not_logged_in_yet

check "host name set" has /etc/hostname '^monitor-test$'
check "hosts entry set" has /etc/hosts '^127\.0\.1\.1[[:space:]]+monitor-test$'
check "time zone set" bash -c '[ "$(readlink /etc/localtime)" = /usr/share/zoneinfo/Europe/Vilnius ]'

check "settings: /etc/homelab 0700" mode_is /etc/homelab 700
check "settings: homelab.env 0600" mode_is /etc/homelab/homelab.env 600
check "settings: homelab.env is the card's file" cmp -s /tmp/expected.env /etc/homelab/homelab.env

check "grafana: admin env 0600" mode_is /etc/homelab/grafana-admin.env 600
gpw="$(field /etc/homelab/grafana-admin.env GF_SECURITY_ADMIN_PASSWORD)"
check "grafana: generated password of 24 characters" test "${#gpw}" -eq 24
check "credentials: file 0600" mode_is /root/homelab-credentials.txt 600
check "credentials: generated Grafana password recorded" has /root/homelab-credentials.txt "^Grafana password: $gpw$"
check "credentials: given homelable password not recorded" bash -c '! grep -q "Test-password-123" /root/homelab-credentials.txt'

h=/etc/homelab/homelable.env
check "homelable: env 0600" mode_is "$h" 600
secret="$(field "$h" SECRET_KEY)"
check "homelable: random secret key (48 characters)" test "${#secret}" -eq 48
check "homelable: not the upstream example key" bash -c "[ '$secret' != change_me_in_production ]"
hash_matches() {
  python3 - "$1" "$2" <<'PY'
import bcrypt, sys
line = next(l for l in open(sys.argv[1]) if l.startswith("AUTH_PASSWORD_HASH="))
stored = line.split("=", 1)[1].strip().strip("'")
sys.exit(0 if bcrypt.checkpw(sys.argv[2].encode(), stored.encode()) else 1)
PY
}
check "homelable: password hash matches the given password" hash_matches "$h" Test-password-123
check "homelable: password hash rejects another password" bash -c "! $(declare -f hash_matches); hash_matches '$h' wrong-password-123"
check "homelable: scan networks" has "$h" "^SCANNER_RANGES='\\[\"192\\.0\\.2\\.0/24\"\\]'$"

check "victoria-metrics: scrape config has the target" has /etc/victoria-metrics/scrape.yml "targets: \\['192\\.0\\.2\\.10:9100'\\]"
check "victoria-metrics: this box named after the host" has /etc/victoria-metrics/scrape.yml "name: 'monitor-test'"
check "victoria-metrics: data dir owned by its user, 0750" bash -c '[ "$(stat -c %U:%a /var/lib/victoria-metrics)" = victoriametrics:750 ]'
check "grafana: loki enabled as asked" bash -c '! grep -E "DISABLE_PLUGINS=.*loki" /etc/grafana/homelab-plugins.env'
check "grafana: unused plugins disabled" has /etc/grafana/homelab-plugins.env '^GF_PLUGINS_DISABLE_PLUGINS=mysql,tempo$'
check "firewall: rules with the LAN networks load" nft -c -f /etc/nftables.conf

# --- 3. homelabctl -------------------------------------------------------------
check "homelabctl check: installed settings valid" /usr/local/sbin/homelabctl check
check "homelabctl check: rejects a bad file" bash -c '! /usr/local/sbin/homelabctl check /tmp/does-not-exist'

e=/etc/homelab/homelab.env
sed -i -e 's/^GRAFANA_PLUGINS=.*/GRAFANA_PLUGINS=/' -e '/^HOMELABLE_SCAN_CIDR=/d' "$e"
printf 'TARGET=app web-1 app.example.invalid:8080 /probe\nLAN_CIDR=198.51.100.0/24\n' >>"$e"
hash_before="$(field "$h" AUTH_PASSWORD_HASH)"
check "apply: succeeds" env HOMELAB_NO_RELOAD=1 /usr/local/sbin/homelabctl apply
check "apply: new target and metrics path" has /etc/victoria-metrics/scrape.yml "__metrics_path__: '/probe'"
check "apply: LAN networks replaced" has /etc/homelab/nftables-lan.nft '^define LAN_V4 = \{ 198\.51\.100\.0/24 \}$'
check "apply: firewall file stays 0600" mode_is /etc/homelab/nftables-lan.nft 600
check "apply: loki disabled again" has /etc/grafana/homelab-plugins.env '^GF_PLUGINS_DISABLE_PLUGINS=loki,mysql,tempo$'
check "apply: homelable scan networks cleared" has "$h" "^SCANNER_RANGES='\\[\\]'$"
check "apply: homelable secret key kept" bash -c "[ \"\$(sed -n 's/^SECRET_KEY=//p' $h)\" = '$secret' ]"
check "apply: homelable password hash kept" bash -c "[ \"\$(sed -n 's/^AUTH_PASSWORD_HASH=//p' $h)\" = \"$hash_before\" ]"
check "apply: homelable env stays 0600" mode_is "$h" 600
check "apply: firewall still loads" nft -c -f /etc/nftables.conf

cp /etc/victoria-metrics/scrape.yml /tmp/scrape.before
printf 'TARGET=node broken 192.0.2.1\n' >>"$e"
check "apply: invalid settings rejected" bash -c '! HOMELAB_NO_RELOAD=1 /usr/local/sbin/homelabctl apply'
check "apply: nothing changed after a rejected file" cmp -s /tmp/scrape.before /etc/victoria-metrics/scrape.yml
sed -i '/^TARGET=node broken/d' "$e"
printf 'GRAFANA_PLUGINS=not-a-plugin\n' >>"$e"
check "apply: unknown Grafana plugin rejected" bash -c '! HOMELAB_NO_RELOAD=1 /usr/local/sbin/homelabctl apply'
sed -i '/^GRAFANA_PLUGINS=not-a-plugin/d' "$e"

# --- 4. First boot again (new card file) ----------------------------------------
cat >/boot/homelab.env <<EOF
HOMELAB_USER=admin
HOMELAB_SSH_KEY="$key"
EOF
check "second first boot: succeeds for an existing user" /usr/local/sbin/homelab-firstboot
check "second first boot: one user entry" bash -c '[ "$(grep -c "^admin:" /etc/passwd)" = 1 ]'
check "second first boot: homelable password generated and recorded" has /root/homelab-credentials.txt '^homelable password: '

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
