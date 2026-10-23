#!/usr/bin/env bash
# Syntax and behaviour checks of the image configuration files with the real
# tools: nftables, nginx, sshd, YAML/JSON parsers. Linux only; needs sudo,
# nft, nginx, sshd and python3 with PyYAML. Runs in CI (quality workflow).
#
# Usage: tests/configs.sh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
rootfs="$repo_root/build/userpatches/overlay/rootfs"
tmp="$(mktemp -d)"
trap 'sudo rm -rf "$tmp"' EXIT

failed=0
ok() { echo "ok   $1"; }
bad() {
  echo "FAIL $1"
  failed=$((failed + 1))
}
run() {
  local desc="$1"
  shift
  if "$@" >"$tmp/out" 2>&1; then ok "$desc"; else
    bad "$desc"
    sed 's/^/     | /' "$tmp/out"
  fi
}

# Rendered files from the example configuration.
"$repo_root/tests/env-case.sh" "$rootfs/usr/local/lib/homelab/homelab.sh" \
  "$repo_root/homelab.env.example" >"$tmp/rendered"
sed -n '/^# Generated/,$p' "$tmp/rendered" | awk 'NR>1 && /^# Generated/{exit} {print}' >"$tmp/scrape.yml"
grep -E '^define LAN_V[46] ' "$tmp/rendered" >"$tmp/lan.nft"

# --- nftables ------------------------------------------------------------------
nft_check() {
  sed "s#/etc/homelab/nftables-lan.nft#$1#" "$rootfs/etc/nftables.conf" >"$tmp/nftables.conf"
  sudo nft -c -f "$tmp/nftables.conf"
}
run "nftables: rules load with the default LAN networks" nft_check "$rootfs/etc/homelab/nftables-lan.nft"
run "nftables: rules load with networks rendered from homelab.env.example" nft_check "$tmp/lan.nft"

# --- nginx ---------------------------------------------------------------------
mkdir -p "$tmp/nginx/logs"
cat >"$tmp/nginx/nginx.conf" <<EOF
pid $tmp/nginx/nginx.pid;
error_log stderr;
events {}
http {
  access_log off;
  client_body_temp_path $tmp/nginx/body;
  proxy_temp_path $tmp/nginx/proxy;
  include $rootfs/etc/nginx/sites-available/homelab;
}
EOF
run "nginx: site configuration is valid" sudo nginx -t -q -p "$tmp/nginx" -c "$tmp/nginx/nginx.conf"

# --- sshd ----------------------------------------------------------------------
sudo install -d -m 0755 /run/sshd # privilege separation dir; absent when sshd is not running
ssh-keygen -q -t ed25519 -N '' -f "$tmp/hostkey"
cat >"$tmp/sshd_config" <<EOF
Include $rootfs/etc/ssh/sshd_config.d/*.conf
HostKey $tmp/hostkey
# What Armbian writes into the main file; the drop-in must still win.
PermitRootLogin yes
PasswordAuthentication yes
EOF
run "sshd: configuration is valid" sudo /usr/sbin/sshd -t -f "$tmp/sshd_config"
# shellcheck disable=SC2024 # output goes to our own temp dir
sudo /usr/sbin/sshd -T -f "$tmp/sshd_config" -C user=root,host=h,addr=192.0.2.1 >"$tmp/sshd-T" 2>&1 || true
for want in "permitrootlogin no" "passwordauthentication no" "kbdinteractiveauthentication no" \
  "authenticationmethods publickey"; do
  run "sshd: effective '$want' despite the main file" grep -qx "$want" "$tmp/sshd-T"
done

# --- YAML and JSON -------------------------------------------------------------
yaml_ok() { python3 -c 'import sys, yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' "$@"; }
run "yaml: Grafana provisioning parses" yaml_ok \
  "$rootfs/etc/grafana/provisioning/datasources/homelab.yaml" \
  "$rootfs/etc/grafana/provisioning/dashboards/homelab.yaml"
scrape_ok() {
  python3 - "$1" <<'EOF'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
jobs = [j["job_name"] for j in cfg["scrape_configs"]]
assert len(jobs) == len(set(jobs)), f"duplicate jobs: {jobs}"
for job in cfg["scrape_configs"]:
    for sc in job["static_configs"]:
        assert sc["targets"] and all(isinstance(t, str) for t in sc["targets"]), sc
EOF
}
run "yaml: default scrape config is valid" scrape_ok "$rootfs/etc/victoria-metrics/scrape.yml"
run "yaml: scrape config rendered from homelab.env.example is valid" scrape_ok "$tmp/scrape.yml"
run "json: dashboard parses and uses the provisioned datasource" python3 - \
  "$rootfs/usr/share/homelab/dashboards/homelab-overview.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["uid"] == "homelab-overview"
for p in d["panels"]:
    if p["type"] != "row":
        assert p["datasource"]["uid"] == "victoriametrics", p["title"]
EOF

# --- homelabctl report ---------------------------------------------------------
# Runs on the CI host (systemd, procps) the way it runs on the board; the
# library is installed where homelabctl expects it (throwaway runner).
sudo install -D -m 0644 "$rootfs/usr/local/lib/homelab/homelab.sh" /usr/local/lib/homelab/homelab.sh
report_ok() {
  # shellcheck disable=SC2024 # output goes to our own temp dir
  sudo bash "$rootfs/usr/local/sbin/homelabctl" report >"$tmp/report" 2>&1 || return 1
  for section in "== Memory (MB)" "== Services:" "== Grafana plugin processes" \
    "== Top processes by RSS" "== Disks" "== Out-of-memory kills since boot:"; do
    grep -qF "$section" "$tmp/report" || {
      echo "missing section: $section"
      cat "$tmp/report"
      return 1
    }
  done
}
run "homelabctl report: runs and prints every section" report_ok

echo
[ "$failed" -eq 0 ] && echo "all config checks passed"
[ "$failed" -eq 0 ]
