#!/usr/bin/env python3
"""Markdown summary of a Trivy JSON report: totals by severity, then the same
counts per source (Debian packages, Grafana, its bundled plugins,
VictoriaMetrics, other binaries), each as "found (fix available)".

Usage: scripts/scan-summary.py <trivy-report.json> <image name> [<grafana plugins env>]

The optional third argument is the image's /etc/grafana/homelab-plugins.env;
when given, findings in bundled plugins that are not loaded by default are
counted separately from the loaded ones.
"""

import json
import re
import sys
from collections import Counter, defaultdict

ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
PLUGIN_RE = re.compile(r"(?:^|/)plugins-bundled/([^/]+)/")


def disabled_plugins(path):
    if not path:
        return None
    for line in open(path):
        if line.startswith("GF_PLUGINS_DISABLE_PLUGINS="):
            return set(filter(None, line.strip().split("=", 1)[1].split(",")))
    return set()


def source_of(result, disabled):
    target = result.get("Target", "")
    if result.get("Class") == "os-pkgs":
        return "Debian packages"
    m = PLUGIN_RE.search(target)
    if m:
        if disabled is not None and m.group(1) in disabled:
            return "Grafana bundled plugins (not loaded by default)"
        return "Grafana bundled plugins (loaded)" if disabled is not None else "Grafana bundled plugins"
    if "/grafana/" in target or target.startswith("usr/share/grafana"):
        return "Grafana"
    if "victoria-metrics" in target:
        return "VictoriaMetrics"
    return target or "other"


def main():
    report = json.load(open(sys.argv[1]))
    image = sys.argv[2]
    disabled = disabled_plugins(sys.argv[3] if len(sys.argv) > 3 else None)

    total, fixable = Counter(), Counter()
    by_source = defaultdict(lambda: (Counter(), Counter()))
    for result in report.get("Results") or []:
        src = source_of(result, disabled)
        for v in result.get("Vulnerabilities") or []:
            sev = v.get("Severity", "UNKNOWN")
            total[sev] += 1
            by_source[src][0][sev] += 1
            if v.get("FixedVersion"):
                fixable[sev] += 1
                by_source[src][1][sev] += 1

    print(f"### Vulnerability scan: `{image}`\n")
    print("| Severity | Found | Fix available |")
    print("|---|---:|---:|")
    for sev in ORDER:
        print(f"| {sev} | {total[sev]} | {fixable[sev]} |")

    if by_source:
        print("\n**By source** — found (fix available):\n")
        print("| Source | " + " | ".join(ORDER) + " |")
        print("|---|" + "---:|" * len(ORDER))
        for src, (found, fix) in sorted(by_source.items(), key=lambda kv: -sum(kv[1][0].values())):
            cells = " | ".join(f"{found[s]} ({fix[s]})" if found[s] else "–" for s in ORDER)
            print(f"| {src} | {cells} |")

    os_info = report.get("Metadata", {}).get("OS", {})
    if os_info:
        print(f"\nOS: {os_info.get('Family', '?')} {os_info.get('Name', '?')}. "
              "Report only; the full list is in `trivy-report.json`.")
    print("\nFixes for Debian packages arrive through security updates on the box; "
          "fixes inside Grafana and VictoriaMetrics need a new upstream release "
          "pinned in `sources.lock`.")


if __name__ == "__main__":
    main()
