# iOS setup guide

Revision 2026-10-09: Automatic PAC URL setup alongside manual configuration.

## Scope and evidence {#safety}

These explanations accompany the stateful setup controls in the app. Read the core setup topic first. Commands, addresses, ports, certificate state and recovery actions come from current app state, not this prose. Profile download is not proof of installation or trust. Captured traffic proves routing only for the observed request; verify HTTPS inspection separately. Obtain authorization before changing routing or trust, and restore the target's normal configuration when finished.

## Guide paragraph 1 {#p1}

Configure your iPhone or iPad to route traffic through JoesProxy for HTTPS inspection.

## Guide paragraph 2 {#p2}

AirDrop the trust profile straight to the device. This is the most reliable option — it works no matter what the device's default browser is.

## Guide paragraph 3 {#p3}

On the device, accept the AirDrop, then open Settings and tap Profile Downloaded. Tap Install, enter your passcode, then tap Install again.

## Guide paragraph 4 {#p4}

Must be opened in Safari specifically — other browsers download the profile as a generic file instead of prompting to install it. If you're not sure which browser will open the link or QR code, use AirDrop above instead.

## Guide paragraph 5 {#p5}

Export the trust profile from this Mac, transfer it to the device some other way, then install it from the Files app or Settings.

## Guide paragraph 6 {#p6}

The profile may display as Not Signed — that is expected for a locally generated development profile.

## Guide paragraph 7 {#p7}

Installing the profile is not enough. HTTPS inspection won't work until you enable full trust in Certificate Trust Settings.

## Guide paragraph 8 {#p8}

Certificate Trust Settings does not appear until the profile has been fully installed.

## Guide paragraph 9 {#p9}

After the certificate is installed and trusted, point the device's Wi-Fi proxy at this Mac. Automatic URL setup serves a PAC file from the running proxy listener, independently of the setup window. Copy Setup URL, then choose Settings > Wi-Fi > your network > Configure Proxy > Automatic on the device. Paste the URL and save. Manual host and port setup remains available.

## Guide paragraph 10 {#p10}

Proxy settings are per Wi-Fi network. Reconfigure if you switch networks or this Mac's IP address or proxy port changes. The default PAC requires the proxy; optional direct fallback permits uncaptured connections when it is unavailable. Neither option provides transaction protection or forces apps to honor the system proxy. iOS can cache PAC configuration; changing fallback mode produces a different URL that must be pasted and saved again. Scanning the QR code only opens the file, not iOS settings. When finished, set Configure Proxy to Off. PAC availability and file download do not establish device routing, certificate trust, or complete capture.

## Guide paragraph 11 {#p11}

Confirm that the device is routing traffic through JoesProxy.

## Guide paragraph 12 {#p12}

Opens a 60-second watch. Generate a request on the iPhone or iPad, then confirm that the captured request came from that device. Traffic from another client does not verify this device's routing. Downloading its PAC file is excluded from capture history and cannot satisfy this check.

## Guide paragraph 13 {#p13}

Confirm the proxy settings on the device match this Mac's address and port, then try again.

## Guide paragraph 14 {#p14}

Open this QR code with the iPhone or iPad camera — it's encoded to open directly in Safari (required for the install prompt), even if Safari isn't the device's default browser.
