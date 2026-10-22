#!/usr/bin/env bash
# Leak check for this public repository. Run before every push; CI runs it on
# every pull request.
#
# Checks:
#   1. gitleaks over the full git history (secrets, keys, tokens);
#   2. tracked and untracked (not ignored) files for private IPv4 addresses,
#      MAC addresses and internal host-name patterns;
#   3. commit messages and author/committer identities for the same patterns
#      and for AI attribution lines;
#   4. an optional private denylist (words that must never appear), given in
#      $LEAK_DENYLIST (newline separated) and/or the file $LEAK_DENYLIST_FILE.
#      Denylist hits are reported as file:line only, so the words themselves
#      never show up in public CI logs.
#
# Allowed on purpose: documentation ranges (192.0.2.0/24, 198.51.100.0/24,
# 203.0.113.0/24) and the bare private network ranges used in firewall rules
# (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10).
#
# Environment:
#   LEAK_CHECK_SKIP_GITLEAKS=1   skip step 1 (only if gitleaks is unavailable)
#   LEAK_CHECK_LOG_RANGE=<range> commits to check in step 3 (default: all)
#   PR_TITLE, PR_BODY            pull request text, checked like commit messages

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail=0
report() {
  printf 'LEAK: %s\n' "$*" >&2
  fail=1
}

# Private IPv4: 10/8, 172.16/12, 192.168/16, 100.64/10 (CGNAT, also used by VPNs).
ip_re='(^|[^0-9.])(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
mac_re='([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'
host_re='(^|[^A-Za-z0-9])(runner[0-9]|gh[r]unner)'
ai_re='co-authored-by:.*(claude|anthropic|copilot|openai|chatgpt|gemini)|generated with .*(claude|copilot|chatgpt)|noreply@anthropic\.com'
allowed_ranges='10\.0\.0\.0/8|172\.16\.0\.0/12|192\.168\.0\.0/16|100\.64\.0\.0/10'

# Denylist: merge env and file into one temporary pattern file.
deny_file="$(mktemp)"
trap 'rm -f "$deny_file"' EXIT
if [ -n "${LEAK_DENYLIST:-}" ]; then
  printf '%s\n' "$LEAK_DENYLIST" >>"$deny_file"
fi
if [ -n "${LEAK_DENYLIST_FILE:-}" ]; then
  cat "$LEAK_DENYLIST_FILE" >>"$deny_file"
fi
# Drop empty lines and comments; an empty pattern would match everything.
grep -vE '^[[:space:]]*(#|$)' "$deny_file" >"$deny_file.tmp" || true
mv "$deny_file.tmp" "$deny_file"
have_deny=0
[ -s "$deny_file" ] && have_deny=1

# 1. gitleaks
if [ "${LEAK_CHECK_SKIP_GITLEAKS:-0}" = 1 ]; then
  echo "gitleaks: skipped (LEAK_CHECK_SKIP_GITLEAKS=1)"
elif command -v gitleaks >/dev/null 2>&1; then
  if ! gitleaks git --redact --no-banner --log-level warn .; then
    report "gitleaks found secrets (see above)"
  fi
else
  report "gitleaks is not installed (set LEAK_CHECK_SKIP_GITLEAKS=1 to skip)"
fi

# 2. Files. Strip the allowed bare ranges first, then match what is left.
scan_files() {
  local name="$1" re="$2" hits
  hits="$(git grep -nIE --untracked "$re" -- . 2>/dev/null |
    sed -E "s#${allowed_ranges}##g" | grep -E "$re" || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    report "$name found in files"
  fi
}
scan_files "private IPv4 address" "$ip_re"
scan_files "MAC address" "$mac_re"
scan_files "internal host name" "$host_re"

if [ "$have_deny" = 1 ]; then
  hits="$(git grep -nIiF --untracked -f "$deny_file" -- . 2>/dev/null | cut -d: -f1,2 || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    report "denylisted word found in files (locations above)"
  fi
fi

# 3. Commit messages and identities.
if git rev-parse --verify -q HEAD >/dev/null; then
  range="${LEAK_CHECK_LOG_RANGE:-HEAD}"
  log="$(git log --format='commit %h%n%an <%ae>%n%cn <%ce>%n%B' "$range")"
  for pair in "private IPv4 address|$ip_re" "MAC address|$mac_re" \
    "internal host name|$host_re" "AI attribution|$ai_re"; do
    name="${pair%%|*}" re="${pair#*|}"
    if printf '%s\n' "$log" | sed -E "s#${allowed_ranges}##g" | grep -qiE "$re"; then
      printf '%s\n' "$log" | grep -iE "^commit |$re" | grep -iB1 -E "$re" >&2 || true
      report "$name found in commit messages or identities"
    fi
  done
  if [ "$have_deny" = 1 ]; then
    commits="$(git log --format='%h' "$range" | while read -r c; do
      if git log -1 --format='%an <%ae>%n%cn <%ce>%n%B' "$c" | grep -qiF -f "$deny_file"; then
        echo "$c"
      fi
    done)"
    if [ -n "$commits" ]; then
      printf '%s\n' "$commits" | sed 's/^/commit /' >&2
      report "denylisted word found in commit messages or identities (commits above)"
    fi
  fi
fi

# 5. Pull request text (set by CI).
if [ -n "${PR_TITLE:-}${PR_BODY:-}" ]; then
  text="$(printf '%s\n%s\n' "${PR_TITLE:-}" "${PR_BODY:-}" | sed -E "s#${allowed_ranges}##g")"
  for pair in "private IPv4 address|$ip_re" "MAC address|$mac_re" \
    "internal host name|$host_re" "AI attribution|$ai_re"; do
    name="${pair%%|*}" re="${pair#*|}"
    if printf '%s\n' "$text" | grep -qiE "$re"; then
      report "$name found in pull request title or description"
    fi
  done
  if [ "$have_deny" = 1 ] && printf '%s\n' "$text" | grep -qiF -f "$deny_file"; then
    report "denylisted word found in pull request title or description"
  fi
fi

[ "$have_deny" = 1 ] || echo "note: no private denylist given (LEAK_DENYLIST / LEAK_DENYLIST_FILE)"

if [ "$fail" -ne 0 ]; then
  echo "leak check FAILED" >&2
  exit 1
fi
echo "leak check passed"
