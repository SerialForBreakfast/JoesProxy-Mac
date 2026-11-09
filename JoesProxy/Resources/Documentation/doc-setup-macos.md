# macOS setup guide

## Scope and evidence {#safety}

These explanations accompany the stateful setup controls in the app. Read the core setup topic first. Commands, addresses, ports, certificate state and recovery actions come from current app state, not this prose. Profile download is not proof of installation or trust. Captured traffic proves routing only for the observed request; verify HTTPS inspection separately. Obtain authorization before changing routing or trust, and restore the target's normal configuration when finished.

## Guide paragraph 1 {#p1}

Install and trust the JoesProxy root CA so HTTPS traffic can be inspected on this Mac.

## Guide paragraph 2 {#p2}

Generate the JoesProxy Root CA used to inspect HTTPS traffic on this Mac.

## Guide paragraph 3 {#p3}

Add the certificate to the macOS login keychain so this Mac can recognize it.

## Guide paragraph 4 {#p4}

HTTPS inspection won't work until the certificate is explicitly set to Always Trust.

## Guide paragraph 5 {#p5}

macOS will ask for your login password to modify the keychain.

## Guide paragraph 6 {#p6}

Confirm that HTTPS traffic from this Mac routes through JoesProxy.

## Guide paragraph 7 {#p7}

Opens the built-in verification endpoint in your browser and watches for the request in JoesProxy.

## Guide paragraph 8 {#p8}

Ensure the proxy is running and the certificate is trusted, then try again.
