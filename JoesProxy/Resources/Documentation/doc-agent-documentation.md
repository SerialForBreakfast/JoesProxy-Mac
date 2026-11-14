# Documentation discovery

## Find the right guidance {#discovery}

Call documentation_list or documentation_search, then documentation_read with the returned topic and optional section. Follow nextCursor with identical query arguments. Read the scope and safety context before acting. Prefer bounded sections over the entire diagnostic playbook.

Source revision 2026-10-29: in MCP Management, the human starts the server, enrolls the agent,
selects disclosure and exports its connection configuration and Skill. The agent verifies the
running identity and uses agent_toolset_status / agent_toolset_select to narrow discovery.
Select all when checking coverage; joesproxy://agent/capabilities exposes the full runtime catalog.
Toolset selection changes discovery, not permissions. UI-only actions remain human steps.

Route capture/body questions to capturedSessions, requestInspector and workflow-evidence;
mocking to workflow-mocking, workflow-image and localOverrides; media to mediaInfo and
hub-mediaInfo; lifecycle/comparisons to workflow-evidence. Use reference-tools and reference-cli
for specialized or otherwise unlisted operations. Search first and read only the relevant section.
Available schemas and grants are authoritative; a static skill is not proof every feature is callable.

## Offline CLI {#offline}

The bundled CLI supports docs list, docs search --query "missing body", and docs read --topic workflow-evidence. Documentation defaults to offline; no credential access, app launch or MCP connection is required. Use --format json for structured output. If copying the CLI alone, retain its app resource package or use a complete installation.

## Live documentation {#live}

Use --source live for the running server's documentation. Connection failures do not silently fall back. MCP clients use the documentation tools or joesproxy://docs/index. A configured MCP connector can avoid CLI executable-path and subprocess sandbox restrictions, but does not bypass authentication, disclosure policy, local file permissions or approvals.

Recovery guidance revised 2026-09-22: the agent checks the configured endpoint and runs `joesproxyctl doctor` when a connection fails. If MCP is stopped, the human starts it in JoesProxy. A temporarily missing current verifier can recover automatically when Keychain access returns. Check the endpoint and retry a read. A revoked or permanently missing credential requires local enrollment or rotation, followed by `joesproxyctl auth login`; reconnecting does not grant authority. The CLI saves a logical session only after initialization completes. Read-only requests may renew an expired session; effect-changing commands do not automatically replay after a stale session or interrupted connection. Inspect the affected bundle, revision and delivery evidence before explicitly retrying an operation whose outcome is unknown. A validation error requires correcting the supplied arguments, not rotating credentials or restarting capture. Unexpected HTTP response bodies are not copied into CLI errors.

## Check version and authority {#version}

Compare the catalog source, revision and app version with the running runtime identity. Installed documentation is not proof of running tool availability or grants. Discover exact schemas and use existing readiness tools before authorized work. Documentation examples are guidance, not permission to run commands or control a device.

## Agent workspace and human supervision {#workspace}

Revision: 2026-09-20. Agent workspace is a lightweight supervision surface in the full app, not a different authorization profile. It keeps runtime controls, approvals, management, setup readiness, capture recovery, save/export and Help available without constructing Inspector. Compact mode is a separate window presentation choice. The Inspector-free prototype is experimental and is not a second shipping product.

The human chooses the next launch workspace in Settings. That preference does not switch the current workspace. In Agent workspace, the human chooses Open Inspector for visual investigation. In Inspector, Tools → Return to Agent Workspace releases visual presentation while retaining shared captures and query services. An unfinished Inspector editor, export, recovery or other protected operation can block departure: finish or close the named operation, then retry the switch. Do not restart capture or clear history to force a workspace change.

Agents continue using discovered MCP/CLI capabilities regardless of the visible workspace or selected tab. Switching workspaces or closing a supervision window does not grant approval, stop effects, revoke credentials, or confirm cleanup. The local user resolves live approvals; the agent polls the specific request and retries only the approved action. Keep revision, ownership and expiry evidence explicit.

If setup or recovery fails, the human opens Setup Readiness or Capture Recovery and reviews the retained result. Restore refuses to replace a nonempty capture. Start Fresh dismisses the saved-capture offer; it does not erase the saved capture. Save Capture exports the whole retained capture, not an Inspector selection. Accepted exports retain their result in the shared owner even if the window closes. Missing or evicted bodies remain unavailable; changing workspace cannot recreate them.

After an experiment, the agent stops its owned effects through the supported tools and reads cleanup evidence. A stopped proxy or hidden HUD is not proof of cleanup. For unavailable commands, discover the running build and read its documentation rather than assuming prototype or future capability parity.
