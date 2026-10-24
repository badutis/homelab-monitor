# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub:
**Security → Report a vulnerability** on this repository. Do not open a public
issue for a vulnerability.

Include what is affected (image version, component, configuration), how to
reproduce it and the impact you expect. You will get an answer as soon as
possible; fixes are released as a new image version.

## Scope

- The build scripts, CI workflows and first-boot configuration in this
  repository.
- How the image configures bundled software (SSH, firewall, service exposure,
  default credentials).

Vulnerabilities in the bundled upstream software (Armbian, Linux, Grafana,
VictoriaMetrics, homelable, Debian packages) should be reported upstream as
well; we pick up fixes through `sources.lock` and new images.

## What the project checks

Every pull request runs:

- a leak check (`gitleaks`, private addresses, MAC addresses, host names,
  AI-attribution lines, a private denylist) over files, commits and PR text;
- `shellcheck`, `shfmt`, `actionlint` and `zizmor` (GitHub Actions security);
- tests: `homelab.env` parsing (including injection attempts), the first-boot
  service end to end in Debian trixie, firewall/nginx/sshd configuration with
  the real tools, image tooling (see the README for the full list).

Every image build is scanned with Trivy (vulnerability report, CycloneDX
SBOM); CRITICAL and HIGH findings of `develop` builds appear in the Security
tab, with a weekly rebuild for new CVEs. `scripts/test-image.sh` checks the
built image itself: key-only SSH without root login, no console autologin,
no configuration or secrets baked in, services on localhost, firewall policy.

Supply chain:

- third-party actions pinned by commit SHA, updated by Dependabot;
- upstream sources pinned by tag and commit, release artifacts by SHA256
  (`sources.lock`); homelable's Python dependencies by SHA256, its web UI
  built with `npm ci --ignore-scripts`;
- Dependabot alerts cover homelable's Python dependencies;
- releases carry `SHA256SUMS` and a build provenance attestation for every
  asset (`gh attestation verify`).
