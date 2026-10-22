#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # HL_* variables are read by the scripts that source this
# homelab-monitor configuration library: parse and validate homelab.env and
# render the files generated from it. Sourced by homelab-firstboot and
# homelabctl; pure functions (no side effects) so they can be tested off the
# board.
#
# homelab.env is read line by line and never executed: anyone with the SD
# card can write it, so every key is whitelisted and every value checked
# against a strict pattern. Unknown keys are errors (fail closed).

# Defaults for optional settings.
HL_DEFAULT_RETENTION="1y"
HL_DEFAULT_SCRAPE_INTERVAL="30s"
HL_DEFAULT_LAN_CIDRS=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7 fe80::/10)

# Reserved account names that HOMELAB_USER must not take.
HL_RESERVED_USERS=" root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc nobody systemd-network systemd-resolve messagebus sshd grafana victoriametrics prometheus nginx _apt "

hl_reset() {
  HL_USER=""
  HL_SSH_KEYS=()
  HL_HOSTNAME=""
  HL_TIMEZONE=""
  HL_DATA_DISK_UUID=""
  HL_GRAFANA_ADMIN_PASSWORD=""
  HL_HOMELABLE_ADMIN_PASSWORD=""
  HL_GRAFANA_PLUGINS=()
  HL_RETENTION="$HL_DEFAULT_RETENTION"
  HL_SCRAPE_INTERVAL="$HL_DEFAULT_SCRAPE_INTERVAL"
  HL_TARGETS=()
  HL_LAN_CIDRS=()
  HL_ERRORS=()
}

hl_error() { HL_ERRORS+=("$1"); }

# Strip one pair of matching surrounding quotes.
hl_unquote() {
  local v="$1"
  if [[ ${#v} -ge 2 && (("${v:0:1}" == '"' && "${v: -1}" == '"') || ("${v:0:1}" == "'" && "${v: -1}" == "'")) ]]; then
    v="${v:1:${#v}-2}"
  fi
  printf '%s' "$v"
}

hl_valid_ipv4_cidr() {
  local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$'
  [[ "$1" =~ $re ]] || return 1
  local i
  for i in 1 2 3 4; do ((BASH_REMATCH[i] <= 255)) || return 1; done
  ((BASH_REMATCH[5] <= 32))
}

hl_valid_ipv6_cidr() {
  local re='^[0-9A-Fa-f:]+/([0-9]{1,3})$'
  [[ "$1" =~ $re ]] || return 1
  [[ "$1" == *:* ]] || return 1
  ((BASH_REMATCH[1] <= 128))
}

# host:port where host is a DNS name, an IPv4 address or [IPv6].
hl_valid_address() {
  local re_name='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?:[0-9]{1,5}$'
  local re_v6='^\[[0-9A-Fa-f:.]+\]:[0-9]{1,5}$'
  [[ "$1" =~ $re_v6 || "$1" =~ $re_name ]] || return 1
  local port="${1##*:}"
  ((10#$port >= 1 && 10#$port <= 65535))
}

# hl_parse_env <file>: fill the HL_* variables; returns 1 and fills
# HL_ERRORS (with line numbers) if anything is invalid.
hl_parse_env() {
  local file="$1" n=0 raw line key value
  hl_reset
  if [[ ! -r "$file" ]]; then
    hl_error "cannot read $file"
    return 1
  fi
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    n=$((n + 1))
    line="${raw%$'\r'}" # files written on Windows/macOS editors
    # Trim surrounding whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" == *[[:cntrl:]]* ]]; then
      hl_error "line $n: control characters are not allowed"
      continue
    fi
    if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      hl_error "line $n: expected KEY=value"
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="$(hl_unquote "${BASH_REMATCH[2]}")"
    hl_set "$n" "$key" "$value"
  done <"$file"

  [[ -n "$HL_USER" ]] || hl_error "HOMELAB_USER is required"
  [[ ${#HL_SSH_KEYS[@]} -gt 0 ]] || hl_error "at least one HOMELAB_SSH_KEY is required"
  [[ ${#HL_LAN_CIDRS[@]} -gt 0 ]] || HL_LAN_CIDRS=("${HL_DEFAULT_LAN_CIDRS[@]}")
  [[ ${#HL_ERRORS[@]} -eq 0 ]]
}

hl_set() {
  local n="$1" key="$2" v="$3"
  case "$key" in
    HOMELAB_USER)
      if [[ ! "$v" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        hl_error "line $n: HOMELAB_USER must be a lowercase user name (a-z, 0-9, _ and -)"
      elif [[ "$HL_RESERVED_USERS" == *" $v "* ]]; then
        hl_error "line $n: HOMELAB_USER '$v' is a reserved system account"
      else
        HL_USER="$v"
      fi
      ;;
    HOMELAB_SSH_KEY)
      local re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [ -~]*)?$'
      if [[ "$v" =~ $re ]]; then
        HL_SSH_KEYS+=("$v")
      else
        hl_error "line $n: HOMELAB_SSH_KEY is not a single OpenSSH public key line"
      fi
      ;;
    HOSTNAME)
      if [[ "$v" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        HL_HOSTNAME="$v"
      else
        hl_error "line $n: HOSTNAME must be one lowercase DNS label"
      fi
      ;;
    TIMEZONE)
      if [[ "$v" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; then
        HL_TIMEZONE="$v"
      else
        hl_error "line $n: TIMEZONE must look like Region/City"
      fi
      ;;
    DATA_DISK_UUID)
      if [[ -z "$v" || "$v" =~ ^[0-9A-Fa-f-]{4,36}$ ]]; then
        HL_DATA_DISK_UUID="$v"
      else
        hl_error "line $n: DATA_DISK_UUID must be a filesystem UUID (see blkid)"
      fi
      ;;
    GRAFANA_ADMIN_PASSWORD | HOMELABLE_ADMIN_PASSWORD)
      if [[ -n "$v" && ${#v} -lt 12 ]]; then
        hl_error "line $n: $key must be at least 12 characters (or empty to generate one)"
      elif [[ -n "$v" && ! "$v" =~ ^[!-~]+$ ]]; then
        hl_error "line $n: $key may only contain printable ASCII without spaces"
      elif [[ "$key" == GRAFANA_ADMIN_PASSWORD ]]; then
        HL_GRAFANA_ADMIN_PASSWORD="$v"
      else
        HL_HOMELABLE_ADMIN_PASSWORD="$v"
      fi
      ;;
    GRAFANA_PLUGINS)
      # Extra Grafana bundled plugins to load; checked against the installed
      # list when applied (hl_render_grafana_plugins).
      if [[ -z "$v" ]]; then
        HL_GRAFANA_PLUGINS=()
      elif [[ "$v" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]; then
        IFS=',' read -r -a HL_GRAFANA_PLUGINS <<<"$v"
      else
        hl_error "line $n: GRAFANA_PLUGINS must be a comma-separated list of plugin ids, e.g. loki,mysql"
      fi
      ;;
    RETENTION)
      if [[ "$v" =~ ^[1-9][0-9]{0,3}[dwy]?$ ]]; then
        HL_RETENTION="$v"
      else
        hl_error "line $n: RETENTION must be months (12) or a duration like 90d, 8w, 1y"
      fi
      ;;
    SCRAPE_INTERVAL)
      if [[ "$v" =~ ^([1-9][0-9]{0,3})s$ ]] && ((BASH_REMATCH[1] >= 5)); then
        HL_SCRAPE_INTERVAL="$v"
      else
        hl_error "line $n: SCRAPE_INTERVAL must be seconds, at least 5s (e.g. 30s)"
      fi
      ;;
    LAN_CIDR)
      if hl_valid_ipv4_cidr "$v" || hl_valid_ipv6_cidr "$v"; then
        HL_LAN_CIDRS+=("$v")
      else
        hl_error "line $n: LAN_CIDR must be an IPv4 or IPv6 network, e.g. 192.0.2.0/24"
      fi
      ;;
    TARGET)
      hl_set_target "$n" "$v"
      ;;
    *)
      hl_error "line $n: unknown setting $key"
      ;;
  esac
}

# TARGET=<job> <name> <host:port> [<metrics path>]
hl_set_target() {
  local n="$1" v="$2" job name addr path extra
  read -r job name addr path extra <<<"$v"
  path="${path:-/metrics}"
  if [[ -n "$extra" || -z "$addr" ]]; then
    hl_error "line $n: TARGET must be '<job> <name> <host:port> [<path>]'"
  elif [[ ! "$job" =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
    hl_error "line $n: TARGET job must be lowercase letters, digits and _ (e.g. node)"
  elif [[ "$job" == homelab_monitor ]]; then
    hl_error "line $n: TARGET job 'homelab_monitor' is reserved for this box"
  elif [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
    hl_error "line $n: TARGET name may contain letters, digits, '.', '_' and '-'"
  elif ! hl_valid_address "$addr"; then
    hl_error "line $n: TARGET address must be host:port (port 1-65535)"
  elif [[ ! "$path" =~ ^/[A-Za-z0-9._/-]*$ ]]; then
    hl_error "line $n: TARGET path must start with / and contain only letters, digits, '.', '_', '-' and '/'"
  else
    local t
    for t in "${HL_TARGETS[@]}"; do
      if [[ "${t#*|}" == "$name|"* ]]; then
        hl_error "line $n: TARGET name '$name' is used twice"
        return
      fi
    done
    HL_TARGETS+=("$job|$name|$addr|$path")
  fi
}

# hl_render_scrape <self name>: VictoriaMetrics/Prometheus scrape config.
# Values were validated by hl_parse_env, so plain single quoting is safe.
hl_render_scrape() {
  local self="$1" job t tjob tname taddr tpath
  printf '# Generated by homelabctl from /etc/homelab/homelab.env; do not edit.\n'
  printf 'global:\n  scrape_interval: %s\n' "$HL_SCRAPE_INTERVAL"
  printf 'scrape_configs:\n'
  printf "  - job_name: homelab_monitor\n    static_configs:\n"
  printf "      - targets: ['127.0.0.1:9100']\n        labels: {name: '%s'}\n" "$self"
  printf "      - targets: ['127.0.0.1:8428']\n        labels: {name: '%s', __metrics_path__: '/metrics'}\n" "$self"

  local jobs=()
  for t in "${HL_TARGETS[@]}"; do
    tjob="${t%%|*}"
    [[ " ${jobs[*]} " == *" $tjob "* ]] || jobs+=("$tjob")
  done
  for job in "${jobs[@]}"; do
    printf '  - job_name: %s\n    static_configs:\n' "$job"
    for t in "${HL_TARGETS[@]}"; do
      IFS='|' read -r tjob tname taddr tpath <<<"$t"
      [[ "$tjob" == "$job" ]] || continue
      printf "      - targets: ['%s']\n        labels: {name: '%s', __metrics_path__: '%s'}\n" \
        "$taddr" "$tname" "$tpath"
    done
  done
}

# hl_render_nft_lan: nftables sets of networks allowed to reach SSH and HTTP.
hl_render_nft_lan() {
  local c v4=() v6=()
  for c in "${HL_LAN_CIDRS[@]}"; do
    if [[ "$c" == *:* ]]; then v6+=("$c"); else v4+=("$c"); fi
  done
  printf '# Generated by homelabctl from /etc/homelab/homelab.env; do not edit.\n'
  printf 'define LAN_V4 = { %s }\n' "$(hl_join ', ' "${v4[@]:-127.0.0.1/32}")"
  printf 'define LAN_V6 = { %s }\n' "$(hl_join ', ' "${v6[@]:-::1/128}")"
}

# Grafana bundled plugins that are always loaded: the datasource for
# VictoriaMetrics.
HL_GRAFANA_REQUIRED_PLUGINS=(prometheus)

# hl_render_grafana_plugins <file with available plugin ids, one per line>:
# environment file that disables every bundled plugin except the required
# ones and those in GRAFANA_PLUGINS. Disabled plugins stay on disk but are not
# loaded (no process, no memory). Returns 1 with HL_ERRORS for unknown ids.
hl_render_grafana_plugins() {
  local available_file="$1" id p enabled=() disabled=() available=()
  mapfile -t available < <(grep -E '^[a-z0-9-]+$' "$available_file")
  for p in "${HL_GRAFANA_PLUGINS[@]}"; do
    if [[ " ${available[*]} " != *" $p "* ]]; then
      hl_error "GRAFANA_PLUGINS: '$p' is not a bundled plugin (available: $(hl_join ', ' "${available[@]}"))"
    fi
  done
  [[ ${#HL_ERRORS[@]} -eq 0 ]] || return 1
  enabled=("${HL_GRAFANA_REQUIRED_PLUGINS[@]}" "${HL_GRAFANA_PLUGINS[@]}")
  for id in "${available[@]}"; do
    [[ " ${enabled[*]} " == *" $id "* ]] || disabled+=("$id")
  done
  printf '# Generated by homelabctl from GRAFANA_PLUGINS in /etc/homelab/homelab.env; do not edit.\n'
  printf 'GF_PLUGINS_DISABLE_PLUGINS=%s\n' "$(hl_join ',' "${disabled[@]}")"
}

hl_join() {
  local sep="$1" out="" x
  shift
  for x in "$@"; do out+="${out:+$sep}$x"; done
  printf '%s' "$out"
}
