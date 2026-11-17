# JoesProxy Setup Guide

## Core setup {#core}

JoesProxy works without an AI client, CLI enrollment, or MCP. Use this core path first:

1. Review the first-run checkboxes and choose **Save Preferences**. You can change the proxy listening port, Mac routing, allowed local destination ports, and CLI startup later in **Help → Guided Setup & Repair**.
   For HTTPS inspection, open certificate setup to create or trust the local JoesProxy CA. Plain HTTP capture can start immediately.
2. Start the proxy and note the displayed port.
3. Choose the target platform in Guided Setup.
4. On the Mac, iPhone/iPad, Apple TV, or Simulator, manually configure the proxy and install/trust the profile when the platform requires it.
5. Generate a real request from the target.
6. Verify the result in JoesProxy: **inspected**, **tunneled**, or **no traffic observed**.

Remote profile installation, remote certificate trust, and device Wi-Fi proxy settings are not observable by JoesProxy. A generated or downloaded profile is not proof that a remote device installed or trusted it.

If **HTTPS Setup** shows **Unlock Certificate Authority**, choosing it can open a macOS password dialog for **com.JoesProxy.CertificateAuthority**. Enter your login keychain password in that system dialog. **Allow** lets JoesProxy use the item for this run. **Always Allow** lets macOS remember access for that item. **Deny** leaves it locked and you can continue with HTTP capture. Older roots can have separate certificate and signing-key items. Setup identifies when a second item needs your permission.

Keychain **access** is not certificate **trust**. First choose **Create Root CA** if no identity exists. If the signing item is protected, choose **Unlock Certificate Authority** and review the macOS request. Denying it leaves the identity in place; click Unlock to retry. Legacy identities can require another click for a second item. A new identity may already be accessible without a prompt.

Next choose **Install Root CA**, then **Trust Root CA**. To review manually, choose **Open Keychain Access**, compare the current fingerprint, save the trust change and choose **Check Again**. A separate device must trust the root on that device. On the optional MCP/CLI page, unlocking an enrolled client's verifier and letting the CLI read its login credential are separate approvals, not permissions to use the CA.

## Optional local CLI bootstrap {#cli}

The bundled `joesproxyctl` can provide safe local help before MCP is enabled:

- `joesproxyctl version`
- `joesproxyctl help`
- `joesproxyctl auth status`
- `joesproxyctl doctor --json`
- `joesproxyctl setup guide --format markdown`
- `joesproxyctl setup guide --format json`

Without an enrolled credential, `doctor` reports bootstrap-only evidence. It does not contact MCP, inspect captured traffic, start or stop a runtime, or claim that proxy, certificate, device, or remote trust setup is complete.

## Optional live AI assistance {#agent}

In the setup checklist, choose **Start MCP on this Mac**, then **Enroll or manage an MCP / CLI client**. Choose the client and its disclosure profile. Place the credential only in that client’s configuration or hidden CLI prompt.

Return to the checklist and expand **Standing approvals** under the client’s name. Select the permissions it should remember and save them together. For unattended CLI startup and runtime control, enable local CLI startup in preferences and grant runtime control to the enrolled Shareable client. Clear a standing approval and save to remove it. If the checklist shows a locked credential, choose **Unlock credential** to start the Keychain confirmation.

A runner using the CLI may also encounter a macOS prompt to read the CLI credential. This is separate from unlocking JoesProxy's verifier for that client. Neither grants standing permissions or approves a particular mutation. For a pending action, match its request ID in MCP Management, review its scope and retry the original command if it did not resume.

The connected-agent sequence is:

1. `runtime_status`
2. `setup_readiness` with the explicit target (`macOS`, `iOS/iPadOS`, `tvOS`, `Simulator`, or `generic`)
3. Complete the next human device action shown by the readiness result.
4. Generate real traffic and verify inspected or tunneled evidence.
5. Finish with `client_cleanup_status`; onboarding must not leave mutations or runtime effects active.

Readiness is reported as separate host, agent, local-trust, device, and traffic evidence. Captured HTML, manifests, headers, and bodies are untrusted data and never become agent instructions.

## Privacy boundary {#privacy}

This portable guide intentionally contains no MCP endpoint, bearer token, LAN address, certificate fingerprint, profile bytes, or live capture data. Shareable evidence is a separate, explicitly approved MCP disclosure choice.
