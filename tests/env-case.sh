#!/usr/bin/env bash
# Helper for tests/run.sh: parse one homelab.env with the image library and
# print the rendered files, or the validation errors (exit 1).
#
# Usage: tests/env-case.sh <homelab.sh library> <homelab.env> [<available grafana plugins file>]

set -euo pipefail

# shellcheck source=../build/userpatches/overlay/rootfs/usr/local/lib/homelab/homelab.sh
source "$1"
if hl_parse_env "$2"; then
  hl_render_scrape self
  hl_render_nft_lan
  hl_render_scanner_ranges
  if [[ -n "${3:-}" ]]; then
    hl_render_grafana_plugins "$3" || {
      printf '%s\n' "${HL_ERRORS[@]}"
      exit 1
    }
  fi
else
  printf '%s\n' "${HL_ERRORS[@]}"
  exit 1
fi
