# Documentation discovery

## Find the right guidance {#discovery}

Source revision 2026-10-29: use the connection configuration and Skill exported by the installed build. The human owns client enrollment, disclosure and live approvals. Inspect agent_toolset_status and select a task-specific toolset through agent_toolset_select; select all when checking coverage. Read joesproxy://agent/capabilities for the running build's complete catalog. Discovery does not grant authority. Prototype availability can differ from the main app; search this build's catalog rather than assuming a main-app topic or operation is present.

Call documentation_list or documentation_search, then documentation_read with the returned topic and optional section. Follow nextCursor with identical query arguments. Read the scope and safety context before acting. Prefer bounded sections over the entire diagnostic playbook.

## Offline CLI {#offline}

The bundled CLI supports docs list, docs search --query "missing body", and docs read --topic setup. Documentation defaults to offline; no credential access, app launch or MCP connection is required. Use --format json for structured output. If copying the CLI alone, retain its app resource package or use a complete installation.

## Live documentation {#live}

Use --source live for the running server's documentation. Connection failures do not silently fall back. MCP clients use the documentation tools or joesproxy://docs/index. A configured MCP connector can avoid CLI executable-path and subprocess sandbox restrictions, but does not bypass authentication, disclosure policy, local file permissions or approvals.

## Check version and authority {#version}

Compare the catalog source, revision and app version with the running runtime identity. Installed documentation is not proof of running tool availability or grants. Discover exact schemas and use existing readiness tools before authorized work. Documentation examples are guidance, not permission to run commands or control a device.
