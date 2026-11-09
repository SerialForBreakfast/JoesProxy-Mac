---
layout: default
title: JoesProxy
---

# Using JoesProxy

JoesProxy is released under the [MIT License](../LICENSE). Use these guides to build it on your Mac and inspect your first request.

## Capture your first request

[Build from source and capture a local HTTP request](GETTING-STARTED.md). Start with the loopback example: finding that request in JoesProxy tells you the listener and capture are working on the Mac. To check another device, route it through the Mac, perform a recognizable action in its app, and look for that new request.

## Inspect HTTPS or share a recording

Read [privacy and local access](PRIVACY.md) before trusting a certificate or sharing a capture. Plain HTTP does not require a certificate. For HTTPS inspection, use the in-app setup guide for your target. An HTTPS connection in the timeline does not by itself mean the response body was decrypted or retained.

A saved recording or HAR can contain sensitive information. Check what it contains before sending it to someone else. Capture processing is local, but an authorized agent can pass evidence it receives to its own service.

## Use an agent or the command line

The app’s Help catalog is searchable. From a terminal, the bundled CLI can also list help topics without enrollment or a running capture:

```sh
joesproxyctl docs list --format json
```

Use the bundled executable’s path if it is not on your shell’s search path. For live agent access, start MCP in JoesProxy and enroll your client on the Mac. Seeing a tool in the catalog does not give the client permission to read a response body or activate a rewrite.

- [CLI reference in the app’s Help catalog](../JoesProxy/Resources/Documentation/doc-reference-cli.md)
- [Diagnostic Skill and workflow guides](../.agents/skills/joesproxy-mcp-diagnostics/SKILL.md)
- [Tested configurations and validation limits](VALIDATION.md)
- [Report a security issue](../SECURITY.md)
