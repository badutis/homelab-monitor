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
  a private denylist);
- `shellcheck`, `shfmt`, `actionlint` and `zizmor` (GitHub Actions security);
- script tests (`tests/run.sh`, `tests/image-tools.sh`).

Every built image is scanned with Trivy (vulnerability report and CycloneDX
SBOM, published as build artifacts).

All third-party actions are pinned by commit SHA and updated by Dependabot.
