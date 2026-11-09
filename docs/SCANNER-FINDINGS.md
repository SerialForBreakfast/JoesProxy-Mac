# Reviewed scanner findings

Revision 2026-11-07. The unsuppressed secret scan of this snapshot reports eight candidates.

| Location | Classification |
|---|---|
| Companion/JoesProxySDK/Tests/JoesProxySDKTests/Fixtures/SDKEventSchema/handshake-v1.json | Fixed synthetic schema token |
| JoesProxyTests/Fixtures/SDKEventSchema/handshake-v1.json | Matching synthetic schema token |
| JoesProxyTests/ProfilingMemoryGuardTests.swift | Token for an isolated local metrics test |
| JoesProxy/CertificateManagement/PersistentCertificateAuthority.swift, two matches | Swift private-key parameter type annotations |
| JoesProxy/MCP/Disclosure/MCPDisclosurePreviewEngine.swift | Adversarial redaction fixture JWT |
| JoesProxyTests/MCP/MCPDisclosureTests.swift, two matches | Adversarial redaction fixture JWTs |

These values or type names exercise schema, redaction and isolation behavior. No service credential was authenticated. No path-wide scanner suppression is supplied. Reclassify a finding if its source changes.
