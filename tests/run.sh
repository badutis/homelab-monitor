#!/usr/bin/env bash
# Tests for the repository scripts. No network access needed: every case runs
# in a throwaway git repository with a copy of scripts/.
#
# Usage: tests/run.sh
#
# Leak fixtures below are split with "" so that this file itself passes the
# repository leak check; the shell joins them back at run time.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
ok() {
  printf 'ok   %s\n' "$1"
  passed=$((passed + 1))
}
not_ok() {
  printf 'FAIL %s\n' "$1"
  failed=$((failed + 1))
}

# expect <0|1> <description> <command...>: exit status must match (0 = success).
expect() {
  local want="$1" desc="$2"
  shift 2
  local got=0
  "$@" >"$tmp/out" 2>&1 || got=1
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    not_ok "$desc"
    sed 's/^/     | /' "$tmp/out"
  fi
}

git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@example.invalid "$@"; }

# New repository with a copy of scripts/ and one clean commit.
new_repo() {
  local dir="$tmp/$1"
  mkdir -p "$dir"
  cp -R "$repo_root/scripts" "$dir/"
  printf 'docs use 192.0.2.10, 198.51.100.7 and the range 10.0.0.0/8\n' >"$dir/clean.txt"
  git_q -C "$dir" init -q
  git_q -C "$dir" add -A
  git_q -C "$dir" commit -qm "init"
  printf '%s\n' "$dir"
}

leak_check() {
  local dir="$1"
  shift
  (cd "$dir" && env LEAK_CHECK_SKIP_GITLEAKS=1 "$@" scripts/leak-check.sh)
}

# --- leak-check.sh ---------------------------------------------------------

d="$(new_repo clean)"
expect 0 "leak-check: clean repository passes" leak_check "$d"

for case in "private-ip|ssh admin@192.""168.1.5" "cgnat-ip|peer 100.""100.1.2" \
  "mac|link aa:bb:cc:dd:ee"":ff" "host|ssh run""ner3"; do
  name="${case%%|*}" text="${case#*|}"
  d="$(new_repo "$name")"
  printf '%s\n' "$text" >"$d/leak.txt"
  expect 1 "leak-check: $name in an untracked file fails" leak_check "$d"
done

d="$(new_repo deny)"
printf 'hello SecretWord\n' >"$d/leak.txt"
expect 1 "leak-check: denylisted word fails" leak_check "$d" LEAK_DENYLIST=$'# comment\n\nsecretword'
if grep -qi secretword "$tmp/out"; then
  not_ok "leak-check: denylisted word is not printed"
else
  ok "leak-check: denylisted word is not printed"
fi

d="$(new_repo ai-commit)"
git_q -C "$d" commit -q --allow-empty -m $'change\n\nCo-Authored'$'-By: Some Bot <noreply@anthropic.com>'
expect 1 "leak-check: AI attribution in a commit message fails" leak_check "$d"

d="$(new_repo identity)"
git -C "$d" -c user.name=x -c user.email=secretword@example.invalid commit -q --allow-empty -m "change"
expect 1 "leak-check: denylisted word in author e-mail fails" leak_check "$d" LEAK_DENYLIST=secretword

d="$(new_repo range)"
git_q -C "$d" commit -q --allow-empty -m "ok"
git_q -C "$d" checkout -q -b side
git_q -C "$d" commit -q --allow-empty -m "temporary merge ssh run""ner3"
expect 0 "leak-check: commits outside LEAK_CHECK_LOG_RANGE are ignored" \
  leak_check "$d" LEAK_CHECK_LOG_RANGE=main
expect 1 "leak-check: commits inside LEAK_CHECK_LOG_RANGE are checked" \
  leak_check "$d" LEAK_CHECK_LOG_RANGE=side

d="$(new_repo pr-text)"
expect 1 "leak-check: AI attribution in PR description fails" \
  leak_check "$d" PR_BODY="Generated with ""Claude Code"
expect 1 "leak-check: private address in PR title fails" \
  leak_check "$d" PR_TITLE="fix 10.""1.2.3"
expect 0 "leak-check: clean PR text passes" \
  leak_check "$d" PR_TITLE="Fix build" PR_BODY="Uses 192.0.2.1 in docs"

# --- fetch-source.sh -------------------------------------------------------

# Upstream with an annotated tag v1 and a lightweight tag v2.
up="$tmp/upstream"
git_q init -q "$up"
git_q -C "$up" commit -q --allow-empty -m one
git_q -C "$up" tag -a v1 -m v1
git_q -C "$up" commit -q --allow-empty -m two
git_q -C "$up" tag v2
c1="$(git -C "$up" rev-parse 'v1^{commit}')"
c2="$(git -C "$up" rev-parse v2)"

fs="$tmp/fs"
mkdir -p "$fs"
cp -R "$repo_root/scripts" "$fs/"
cat >"$fs/sources.lock" <<EOF
good-annotated  repo=file://$up  tag=v1  commit=$c1
good-light      repo=file://$up  tag=v2  commit=$c2
moved           repo=file://$up  tag=v1  commit=$c2
no-commit       repo=file://$up  tag=v1
EOF

expect 0 "fetch-source: annotated tag at pinned commit is cloned" \
  "$fs/scripts/fetch-source.sh" good-annotated "$tmp/c1"
expect 0 "fetch-source: lightweight tag at pinned commit is cloned" \
  "$fs/scripts/fetch-source.sh" good-light "$tmp/c2"
expect 1 "fetch-source: tag at another commit fails" \
  "$fs/scripts/fetch-source.sh" moved "$tmp/c3"
expect 0 "fetch-source --verify-only: annotated tag passes" \
  "$fs/scripts/fetch-source.sh" good-annotated --verify-only
expect 0 "fetch-source --verify-only: lightweight tag passes" \
  "$fs/scripts/fetch-source.sh" good-light --verify-only
expect 1 "fetch-source --verify-only: tag at another commit fails" \
  "$fs/scripts/fetch-source.sh" moved --verify-only
expect 1 "fetch-source: missing commit= fails" \
  "$fs/scripts/fetch-source.sh" no-commit --verify-only
expect 1 "fetch-source: unknown component fails" \
  "$fs/scripts/fetch-source.sh" nope --verify-only

# --- fetch-artifact.sh -----------------------------------------------------

fa="$tmp/fa"
mkdir -p "$fa/files"
cp -R "$repo_root/scripts" "$fa/"
printf 'payload\n' >"$fa/files/artifact.bin"
good_sha="$( (sha256sum "$fa/files/artifact.bin" 2>/dev/null || shasum -a 256 "$fa/files/artifact.bin") | cut -d' ' -f1)"
zeros="0000000000000000000000000000000000000000000000000000000000000000"
cat >"$fa/sources.lock" <<EOF
good      url=file://$fa/files/artifact.bin  sha256=$good_sha
wrong     url=file://$fa/files/artifact.bin  sha256=$zeros
short     url=file://$fa/files/artifact.bin  sha256=abc
no-sha    url=file://$fa/files/artifact.bin
EOF
expect 0 "fetch-artifact: matching sha256 is kept" "$fa/scripts/fetch-artifact.sh" good "$tmp/fa-out"
if [ -f "$tmp/fa-out/artifact.bin" ]; then
  ok "fetch-artifact: file saved under its URL name"
else
  not_ok "fetch-artifact: file saved under its URL name"
fi
expect 1 "fetch-artifact: wrong sha256 fails" "$fa/scripts/fetch-artifact.sh" wrong "$tmp/fa-bad"
if [ -e "$tmp/fa-bad/artifact.bin" ] || [ -e "$tmp/fa-bad/artifact.bin.part" ]; then
  not_ok "fetch-artifact: mismatching file is deleted"
else
  ok "fetch-artifact: mismatching file is deleted"
fi
expect 1 "fetch-artifact: malformed sha256 fails" "$fa/scripts/fetch-artifact.sh" short "$tmp/fa-bad"
expect 1 "fetch-artifact: missing sha256 fails" "$fa/scripts/fetch-artifact.sh" no-sha "$tmp/fa-bad"

# --- homelab.env parsing and rendering (image library) -----------------------

lib="$repo_root/build/userpatches/overlay/rootfs/usr/local/lib/homelab/homelab.sh"
key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForUnitTestsOnly000000000000000000 t@example.invalid"
env_n=0

# env_case <0|1> <description> <file content> [extended regex expected in output]
env_case() {
  local want="$1" desc="$2" content="$3" pattern="${4:-}"
  env_n=$((env_n + 1))
  local f="$tmp/env.$env_n"
  printf '%s' "$content" >"$f"
  expect "$want" "env: $desc" "$repo_root/tests/env-case.sh" "$lib" "$f"
  if [ -n "$pattern" ]; then
    if grep -qE -- "$pattern" "$tmp/out"; then
      ok "env: $desc (output)"
    else
      not_ok "env: $desc (output)"
      sed 's/^/     | /' "$tmp/out"
    fi
  fi
}

base="HOMELAB_USER=admin"$'\n'"HOMELAB_SSH_KEY=\"$key\""$'\n'

env_case 0 "example file is valid" "$(cat "$repo_root/homelab.env.example")" "name: 'rack-controller'"
env_case 0 "minimal file is valid" "$base" "job_name: homelab_monitor"
env_case 0 "default LAN networks" "$base" 'define LAN_V4 = \{ 10\.0\.0\.0/8, 172\.16\.0\.0/12, 192\.168\.0\.0/16 \}'
env_case 0 "LAN_CIDR replaces the defaults" "${base}LAN_CIDR=192.0.2.0/24"$'\n' 'define LAN_V4 = \{ 192\.0\.2\.0/24 \}'
env_case 0 "IPv6-only LAN keeps IPv4 closed" "${base}LAN_CIDR=2001:db8::/32"$'\n' 'define LAN_V4 = \{ 127\.0\.0\.1/32 \}'
env_case 0 "CRLF line endings" "HOMELAB_USER=admin"$'\r\n'"HOMELAB_SSH_KEY=\"$key\""$'\r\n'
env_case 0 "targets grouped by job with path" \
  "${base}TARGET=node a 192.0.2.1:9100"$'\n'"TARGET=app b app.example.invalid:8080 /probe"$'\n' \
  "__metrics_path__: '/probe'"
env_case 0 "IPv6 target" "${base}TARGET=node v6 [2001:db8::1]:9100"$'\n' '\[2001:db8::1\]:9100'
env_case 0 "retention and interval" "${base}RETENTION=90d"$'\n'"SCRAPE_INTERVAL=15s"$'\n' "scrape_interval: 15s"
env_case 1 "missing user and key" "HOSTNAME=x"$'\n' "HOMELAB_USER is required"
env_case 1 "reserved user root" "HOMELAB_USER=root"$'\n'"HOMELAB_SSH_KEY=\"$key\""$'\n' "reserved"
env_case 1 "private key instead of public" \
  "${base}HOMELAB_SSH_KEY=-----BEGIN OPENSSH PRIVATE KEY-----"$'\n' "not a single OpenSSH public key"
env_case 1 "unknown setting" "${base}PERMIT_ROOT=yes"$'\n' "unknown setting PERMIT_ROOT"
env_case 1 "lowercase key" "${base}hostname=x"$'\n' "expected KEY=value"
env_case 1 "command substitution in a value" "${base}HOSTNAME=\$(reboot)"$'\n' "HOSTNAME must be"
env_case 1 "quote injection in target path" "${base}TARGET=node a 192.0.2.1:80 /m'x"$'\n' "TARGET path"
env_case 1 "port 0" "${base}TARGET=node a 192.0.2.1:0"$'\n' "port 1-65535"
env_case 1 "port 65536" "${base}TARGET=node a 192.0.2.1:65536"$'\n' "port 1-65535"
env_case 1 "duplicate target name" \
  "${base}TARGET=node a 192.0.2.1:9100"$'\n'"TARGET=app a 192.0.2.2:80"$'\n' "used twice"
env_case 1 "reserved job" "${base}TARGET=homelab_monitor a 192.0.2.1:9100"$'\n' "reserved"
env_case 1 "too many target fields" "${base}TARGET=node a 192.0.2.1:9100 /metrics extra"$'\n' "must be '<job>"
env_case 1 "control character" "${base}HOSTNAME=a"$'\x01'"b"$'\n' "control characters"
env_case 1 "short Grafana password" "${base}GRAFANA_ADMIN_PASSWORD=short"$'\n' "at least 12"
env_case 1 "Grafana password with space" \
  "${base}GRAFANA_ADMIN_PASSWORD=\"long enough pass\""$'\n' "printable ASCII"
env_case 1 "short homelable password" "${base}HOMELABLE_ADMIN_PASSWORD=short"$'\n' "HOMELABLE_ADMIN_PASSWORD must be at least 12"
env_case 0 "homelable password accepted" "${base}HOMELABLE_ADMIN_PASSWORD=Long-enough-1234"$'\n'
env_case 0 "no homelable scan networks by default" "$base" "^SCANNER_RANGES='\\[\\]'$"
env_case 0 "homelable scan networks" "${base}HOMELABLE_SCAN_CIDR=192.0.2.0/24"$'\n'"HOMELABLE_SCAN_CIDR=198.51.100.0/25"$'\n' \
  "^SCANNER_RANGES='\\[\"192\\.0\\.2\\.0/24\",\"198\\.51\\.100\\.0/25\"\\]'$"
env_case 1 "homelable scan network larger than /16" "${base}HOMELABLE_SCAN_CIDR=10.0.0.0/8"$'\n' "/16 or smaller"
env_case 1 "homelable scan network IPv6" "${base}HOMELABLE_SCAN_CIDR=2001:db8::/64"$'\n' "IPv4 network"
env_case 1 "bad LAN_CIDR" "${base}LAN_CIDR=192.0.2.0/33"$'\n' "LAN_CIDR must be"
env_case 1 "scrape interval below 5s" "${base}SCRAPE_INTERVAL=1s"$'\n' "at least 5s"
env_case 1 "bad retention" "${base}RETENTION=forever"$'\n' "RETENTION must be"
env_case 1 "path traversal in time zone" "${base}TIMEZONE=../../etc/passwd"$'\n' "TIMEZONE must"

# Grafana bundled plugins (the ids Grafana 13.2 ships).
plugins="$tmp/grafana-bundled-plugins"
printf '%s\n' elasticsearch grafana-postgresql-datasource grafana-pyroscope-datasource influxdb \
  jaeger loki mssql mysql opentsdb prometheus stackdriver tempo zipkin >"$plugins"

# plugins_case <0|1> <description> <file content> <extended regex expected in output>
plugins_case() {
  env_n=$((env_n + 1))
  local f="$tmp/env.$env_n"
  printf '%s' "$3" >"$f"
  expect "$1" "grafana plugins: $2" "$repo_root/tests/env-case.sh" "$lib" "$f" "$plugins"
  if grep -qE -- "$4" "$tmp/out"; then
    ok "grafana plugins: $2 (output)"
  else
    not_ok "grafana plugins: $2 (output)"
    sed 's/^/     | /' "$tmp/out"
  fi
}
all_but_prometheus="elasticsearch,grafana-postgresql-datasource,grafana-pyroscope-datasource,influxdb,jaeger,loki,mssql,mysql,opentsdb,stackdriver,tempo,zipkin"
plugins_case 0 "default loads only prometheus" "$base" "^GF_PLUGINS_DISABLE_PLUGINS=${all_but_prometheus}\$"
plugins_case 0 "GRAFANA_PLUGINS enables more" "${base}GRAFANA_PLUGINS=loki,mysql"$'\n' \
  '^GF_PLUGINS_DISABLE_PLUGINS=elasticsearch,grafana-postgresql-datasource,grafana-pyroscope-datasource,influxdb,jaeger,mssql,opentsdb,stackdriver,tempo,zipkin$'
plugins_case 0 "prometheus can not be disabled" "${base}GRAFANA_PLUGINS="$'\n' "^GF_PLUGINS_DISABLE_PLUGINS=${all_but_prometheus}\$"
plugins_case 1 "unknown plugin id" "${base}GRAFANA_PLUGINS=loki,not-a-plugin"$'\n' "'not-a-plugin' is not a bundled plugin"
plugins_case 1 "bad list format" "${base}GRAFANA_PLUGINS=loki mysql"$'\n' "comma-separated list"

# --- scan-summary.py ---------------------------------------------------------

ss="$tmp/scan-summary"
mkdir -p "$ss"
cat >"$ss/report.json" <<'EOF'
{"Metadata": {"OS": {"Family": "debian", "Name": "13.7"}},
 "Results": [
  {"Target": "mkspi (debian 13.7)", "Class": "os-pkgs", "Vulnerabilities": [
    {"Severity": "CRITICAL"}, {"Severity": "HIGH", "FixedVersion": "1.2"}]},
  {"Target": "usr/share/grafana/bin/grafana", "Class": "lang-pkgs", "Vulnerabilities": [
    {"Severity": "HIGH", "FixedVersion": "0.9"}]},
  {"Target": "usr/share/grafana/data/plugins-bundled/loki/gpx_loki", "Class": "lang-pkgs", "Vulnerabilities": [
    {"Severity": "MEDIUM", "FixedVersion": "2"}]},
  {"Target": "usr/share/grafana/data/plugins-bundled/prometheus/gpx_prom", "Class": "lang-pkgs", "Vulnerabilities": [
    {"Severity": "LOW"}]},
  {"Target": "usr/local/bin/victoria-metrics-prod", "Class": "lang-pkgs", "Vulnerabilities": [
    {"Severity": "HIGH", "FixedVersion": "1.27.3"}]},
  {"Target": "usr/lib/empty", "Class": "lang-pkgs"}
 ]}
EOF
printf 'GF_PLUGINS_DISABLE_PLUGINS=loki,tempo\n' >"$ss/plugins.env"
expect 0 "scan-summary: renders" python3 "$repo_root/scripts/scan-summary.py" "$ss/report.json" test.img.xz "$ss/plugins.env"
for want in '| CRITICAL | 1 | 0 |' '| HIGH | 3 | 3 |' \
  '| Debian packages | 1 (0) | 1 (1) | – | – | – |' \
  '| Grafana | – | 1 (1) | – | – | – |' \
  '| Grafana bundled plugins (not loaded by default) | – | – | 1 (1) | – | – |' \
  '| Grafana bundled plugins (loaded) | – | – | – | 1 (0) | – |' \
  '| VictoriaMetrics | – | 1 (1) | – | – | – |' 'OS: debian 13.7'; do
  if grep -qF -- "$want" "$tmp/out"; then ok "scan-summary: $want"; else
    not_ok "scan-summary: $want"
    sed 's/^/     | /' "$tmp/out"
  fi
done
expect 0 "scan-summary: works without the plugin list" python3 "$repo_root/scripts/scan-summary.py" "$ss/report.json" test.img.xz
if grep -qF '| Grafana bundled plugins | – | – | 1 (1) | 1 (0) | – |' "$tmp/out"; then
  ok "scan-summary: plugins counted together without the list"
else
  not_ok "scan-summary: plugins counted together without the list"
  sed 's/^/     | /' "$tmp/out"
fi

# --- sources.lock consistency ----------------------------------------------

lock_field() { grep -E "^$1[[:space:]]" "$repo_root/sources.lock" | tr -s '[:space:]' '\n' | sed -n "s/^$2=//p"; }
if [ "v$(lock_field grafana version)" = "$(lock_field grafana-src tag)" ]; then
  ok "sources.lock: Grafana source tag matches the packaged version"
else
  not_ok "sources.lock: Grafana source tag matches the packaged version"
fi
if grep -q "homelable $(lock_field homelable tag) " "$repo_root/build/homelable/requirements.txt"; then
  ok "sources.lock: homelable dependency lock is for the pinned tag"
else
  not_ok "sources.lock: homelable dependency lock is for the pinned tag (run scripts/update-homelable-lock.sh)"
fi

# --- release notes ---------------------------------------------------------

rel="$tmp/release"
mkdir -p "$rel"
: >"$rel/homelab-monitor-v9.9.9-mkspi.img.xz"
printf '### Vulnerability scan\n' >"$rel/trivy-summary.md"
expect 0 "release-notes: renders" "$repo_root/scripts/release-notes.sh" v9.9.9 "$rel"
for want in "homelab-monitor-v9.9.9-mkspi.img.xz" "blob/v9.9.9/homelab.env.example" \
  "| Grafana OSS | \`$(lock_field grafana version)\` |" "## Vulnerability scan"; do
  if grep -qF -- "$want" "$tmp/out"; then ok "release-notes: contains $want"; else not_ok "release-notes: contains $want"; fi
done

# --- collect-sources.sh (GNU tar only, as on the build host) -----------------

if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  arm="$tmp/armbian"
  for tree in linux-kernel-worktree/6.18__x u-boot-worktree/u-boot/v2026.04 arm-trusted-firmware/v2.13.0; do
    d="$arm/cache/sources/$tree"
    git_q init -q "$d"
    printf '*.o\n.config\n' >"$d/.gitignore"
    printf 'source\n' >"$d/main.c"
    git_q -C "$d" add -A
    git_q -C "$d" commit -qm base
    printf 'patched\n' >"$d/patch.c" # applied patch, not committed
    printf 'obj\n' >"$d/main.o"      # build output
    printf 'CONFIG_X=y\n' >"$d/.config"
  done
  expect 0 "collect-sources: archives the trees" "$repo_root/scripts/collect-sources.sh" "$arm" "$tmp/src-out"
  listing="$(xz -dc "$tmp/src-out/linux-source.tar.xz" | tar -t)"
  for want in linux-source/main.c linux-source/patch.c linux-source/.config; do
    if printf '%s\n' "$listing" | grep -qx "$want"; then ok "collect-sources: kernel archive has $want"; else not_ok "collect-sources: kernel archive has $want"; fi
  done
  if printf '%s\n' "$listing" | grep -q 'main\.o$'; then
    not_ok "collect-sources: build outputs are left out"
  else
    ok "collect-sources: build outputs are left out"
  fi
  if xz -dc "$tmp/src-out/arm-trusted-firmware-source.tar.xz" | tar -t | grep -q '\.config$'; then
    not_ok "collect-sources: .config only added where asked"
  else
    ok "collect-sources: .config only added where asked"
  fi
  if grep -q 'linux-source.tar.xz' "$tmp/src-out/SOURCES.txt"; then
    ok "collect-sources: SOURCES.txt lists the archives"
  else
    not_ok "collect-sources: SOURCES.txt lists the archives"
  fi
else
  echo "skip collect-sources tests (needs GNU tar)"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
