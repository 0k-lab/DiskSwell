# Security Policy

## Supported versions

Only the latest published DiskSwell release receives security fixes. Until the first release is published, the repository should be treated as pre-release software.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use **Security → Report a vulnerability** in the [DiskSwell GitHub repository](https://github.com/kricha-lab/DiskSwell/security/advisories/new) to submit a private report.

Include the affected version, macOS version, impact, reproduction steps, and any suggested mitigation. The maintainers will coordinate disclosure through the private advisory and publish a fix before public details when practical.

Private vulnerability reporting is enabled for this repository.

## Security philosophy

DiskSwell minimizes its attack surface:

- all monitoring and history processing is local;
- networking is limited to optional update checks and user-approved installer downloads from the fixed DiskSwell GitHub Releases endpoints;
- the updater verifies the published SHA-256, requires the installer's Developer ID team to match the running app, and asks Gatekeeper to assess the package before opening it;
- the app contains no telemetry, analytics, accounts, or DiskSwell-operated cloud service;
- it runs without a privileged helper or daemon;
- it uses the current user's permissions and does not automatically request Full Disk Access;
- direct-release builds use Developer ID signing, Hardened Runtime, notarization, and no debug entitlement;
- it never deletes, truncates, or modifies monitored files.

No security model can eliminate all risk. Review the source and verify the published SHA-256 checksum before installation if your environment requires additional assurance.
