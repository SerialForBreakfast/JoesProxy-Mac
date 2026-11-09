# Security and sensitive data

Revision 2026-11-07. Security reports are welcome during the maintainer-led public preview. External code contributions are currently closed.

Do not include real captures, credentials, device profiles, customer endpoints or personal diagnostics in public issues. Prefer a synthetic reproduction and a redacted summary. Review every attachment, including image pixels and metadata, before sharing.

For a suspected vulnerability, use the repository hosting service's private vulnerability-reporting channel if the maintainer has enabled it. If unavailable, ask the maintainer for a private contact channel without disclosing exploit details or secrets publicly. This document does not claim a private reporting channel is already configured.

Include the version/build, affected feature, expected and observed behavior, and a minimal synthetic reproduction. Credential exposure, CA/private-key handling, unauthorized traffic disclosure and approval/revocation failures are useful report categories. Keep exploit details and sensitive attachments in the private channel. Response times depend on maintainer availability.

Read the [privacy guide](docs/PRIVACY.md) for storage and listener behavior and the [security-check plan](docs/SECURITY-CHECKS.md) for current coverage. Public-preview status and scanner results do not certify complete security or privacy.

Test credentials and keys in fixtures are synthetic and must never be reused in a deployed service. Proxy certificates generated locally are not supplied by this source snapshot.
