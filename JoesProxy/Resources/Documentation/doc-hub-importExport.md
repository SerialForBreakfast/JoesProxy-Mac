# Import / Export

## Import / Export 1 {#p1}

Preserves the current session workspace in the native, transparently compressed .jproxy format so it can be reopened later.

## Import / Export 2 {#p2}

This Settings control affects live in-memory capture only. Unlimited keeps everything, Keep Last Sessions drops the oldest sessions first, and Limit Stored Body Data keeps session structure while removing the oldest stored bodies once the configured limit is exceeded.

## Import / Export 3 {#p3}

Full Recording is best for deep debugging, Metadata Only is best for the smallest shareable files, Text Bodies Only keeps readable payloads like JSON, XML, and manifests, and Media Focused keeps streaming manifests, playback metadata, init segments, and bounded media bodies.

## Import / Export 4 {#p4}

Loads a .jproxy recording and lets you replace the current workspace or merge it into existing sessions.

## Import / Export 5 {#p5}

Produces an interop export for other tools. HAR is not the same as a full workspace save, and some JoesProxy-specific state will not round-trip.

## Import / Export 6 {#p6}

If the app previously closed unexpectedly or with large media downloads, launch recovery offers Save .jproxy Recording and Export .har File directly from disk without loading all session bodies into memory.

## Import / Export 7 {#p7}

Choose long-capture storage when deciding how much live data stays in memory while the proxy is running. Choose a recording save mode when deciding how much data to keep in a saved .jproxy file.

## Import / Export 8 {#p8}

Recordings and exports may include sensitive headers, bodies, and device identifiers. Review the selected sessions before sharing files outside your team.

