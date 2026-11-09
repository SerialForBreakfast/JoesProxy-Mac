# Privacy and local access

Revision 2026-11-07. This describes the reviewed 1.9.0 source. It is a source-based explanation; independent review and runtime checks can find additional issues.

## Captured traffic

Inspected HTTP and HTTPS traffic can contain URLs, query parameters, account details, cookies, authorization headers, device identifiers and full bodies. HTTPS inspection requires the local CA to be trusted by the selected client. Tunneling and body-retention limits can leave inspection incomplete.

Production settings default to a 250 MiB limit on retained in-memory bodies. Removing old bodies under that limit preserves session metadata. Per-response retention has its own limit. User settings can change these policies.

Rolling capture recovery is enabled by default. It writes capture data to disk, including a journal and snapshots. The configured defaults retain five rotated snapshots with a 500 MB disk budget. These disk settings are separate from in-memory retention. Review rolling capture settings before handling sensitive traffic.

Normal per-user application storage is resolved through macOS Application Support. For sandboxed builds it can be inside the app's container. Recovery data uses JoesProxy/RollingCaptures under that resolved location, including latest.jproxy, journal.jsonl and checkpoint.json. Selected recordings and exports are written to their chosen destinations.

Sources: [production defaults](../JoesProxy/Configuration/AppConfiguration.swift), [recovery storage](../JoesProxy/Sessions/RollingCapturePersistenceCoordinator.swift), [export guidance](../JoesProxy/Resources/Documentation/doc-exportPrivacy.md).

## Certificates and credentials

The persistent CA store saves its certificate and private-key data through the macOS Keychain. Keep the CA private key private. Only trust a debugging CA on devices you intend to inspect, and remove that trust when it is no longer needed.

MCP stores its client verifier through a device-local Keychain item. The bundled CLI also uses a local credential store. Recordings, saved mock definitions, configuration and application logs have different storage and disclosure rules from Keychain credentials.

Sources: [CA storage](../JoesProxy/CertificateManagement/PersistentCertificateAuthority.swift), [Keychain helper](../JoesProxy/CertificateManagement/KeychainHelper.swift), [MCP credential storage](../JoesProxy/MCP/Clients/MCPClientCredentialKeychainStore.swift).

## Network listeners

The proxy defaults to port 9090 and a bind address of 0.0.0.0. It can accept traffic on LAN interfaces. Use a trusted network and review the selected bind address and port before starting it.

The MCP HTTP transport binds to 127.0.0.1. Its default port is 9091. Client enrollment, disclosure policy and applicable local approvals govern access to tools and captured evidence. A loopback listener still needs credential and permission checks.

The optional SDK event service uses a TCP listener with Bonjour discovery and a pairing token. Its port is configurable and can also default to 9091. The profile-hosting service binds to all local interfaces when started, normally on port 8765, to serve device setup material. Review which optional services are running and their actual ports.

Sources: [proxy defaults](../JoesProxy/NetworkConstants.swift), [proxy listener](../JoesProxy/ProxyServer.swift), [MCP listener](../JoesProxy/MCP/Transport/MCPNIOHTTPTransport.swift), [SDK listener](../JoesProxy/SDK/SDKEventServer.swift), [profile listener](../JoesProxy/ProfileHostingServer.swift).

## Agents and saved artifacts

An enrolled agent can read only the evidence permitted by its current policy, grants and source-specific approvals. Some grants may last for the current session. Check the selected client's disclosure profile before sharing.

Saved artifacts are explicitly selected and reviewed locally. The analysis source is a temporary immutable snapshot with an expiry. Later edits to the original file do not update that snapshot. Revoke its share to end access. Compare once requires two current brief shares plus approval for the exact ordered pair. Revoking either share suppresses the whole comparison result.

An external agent's own provider may receive evidence that JoesProxy returns to it. Review that agent's data-handling terms before sharing captured data. A compact result can still disclose field names, sensitive attributes or exact counts.

Source: [artifact authority and lifetime](../JoesProxy/Analysis/ArtifactSourceRegistry.swift).

## Optional local model features

Mock-icon suggestions and similar-item text proposals use the system Foundation Models API after an explicit user action, with selected input projections and runtime availability checks. Accepted output is reviewed before use. The integration has no remote model fallback.

The source paths below show inference inputs and cancellation boundaries. Operating-system model availability and management are separate from this app's feature controls.

Sources: [icon suggestions](../JoesProxy/EffectBundles/MockIconSuggestion.swift), [similar-item generation](../JoesProxy/EffectBundles/LocalSimilarItemTextGenerator.swift).

## Diagnostics, export and cleanup

MCP audit records are persisted under Application Support/JoesProxy/mcp-audit.json in the normal storage scope. They include identifiers, event kinds and reason details. Previous-run diagnostics are enabled by default. Treat diagnostics and logs as potentially identifying even when body contents are excluded by a particular format.

Large request uploads can use temporary disk spooling under the resolved Application Support/JoesProxy/UploadBodies directory. Recovery data, exported recordings, mock artwork, saved bundles, diagnostics, agent receipts and backups are separate categories to review during cleanup. Stopping the proxy ends active forwarding; persisted files need their own retention review.

Before sharing an export, choose the smallest session selection and recording mode that answers the question, then inspect the actual result. HAR/JSON, headers and images can carry secrets or identifying data. Prefer synthetic reproductions for public reports.

Sources: [audit storage](../JoesProxy/MCP/Audit/MCPAuditStore.swift), [diagnostic composition](../JoesProxy/App/AppCoordinator.swift), [upload spooling](../JoesProxy/Proxying/UploadBodySpool.swift).

## Network and security claims

Normal proxy forwarding contacts requested upstream destinations. Device setup and fixtures can create additional local services. An enrolled external agent has its own network behavior. The source also includes project/support links and an updater feed configuration whose public signing key is still a placeholder.

The checks in [VALIDATION.md](VALIDATION.md) cover specific code and test scenarios. Privacy documentation and passing scans do not certify every network path or behavior. Report a suspected vulnerability using [SECURITY.md](../SECURITY.md).
