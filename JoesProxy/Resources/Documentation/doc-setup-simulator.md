# Simulator setup guide

## Scope and evidence {#safety}

These explanations accompany the stateful setup controls in the app. Read the core setup topic first. Commands, addresses, ports, certificate state and recovery actions come from current app state, not this prose. Profile download is not proof of installation or trust. Captured traffic proves routing only for the observed request; verify HTTPS inspection separately. Obtain authorization before changing routing or trust, and restore the target's normal configuration when finished.

## Guide paragraph 1 {#p1}

Install the JoesProxy Root CA in a booted simulator, route its traffic through JoesProxy, then verify. Each step updates as it completes; advanced and manual options are tucked inside each step.

## Guide paragraph 2 {#p2}

Use Terminal to find a booted simulator UDID, then paste it here so JoesProxy can generate the install and verification commands.

## Guide paragraph 3 {#p3}

Drag this certificate onto an open Simulator window to install the JoesProxy Root CA. No Terminal required.

## Guide paragraph 4 {#p4}

Run this for the selected simulator, then enable full trust inside it.

## Guide paragraph 5 {#p5}

Trust path for iOS-family runtimes: Settings > General > About > Certificate Trust Settings.

## Guide paragraph 6 {#p6}

The Simulator has no proxy settings of its own — it inherits the macOS system proxy. Turn this on to route Simulator (and Mac) traffic through JoesProxy after you manually start capture in JoesProxy. MCP and CLI cannot activate this routing.

## Guide paragraph 7 {#p7}

A Simulator that was already running may take a few seconds — or a restart — to pick up the proxy.

## Guide paragraph 8 {#p8}

Off. Turn on the toggle above to route automatically, or use the manual option.

## Guide paragraph 9 {#p9}

JoesProxy opens a test page in the selected simulator and watches for the request to arrive. Run this after Step 3 shows Active.

## Guide paragraph 10 {#p10}

Open this URL in the simulator's Safari, or run the command, then watch JoesProxy for a the built-in verification endpoint session.
