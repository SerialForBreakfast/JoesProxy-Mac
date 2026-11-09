# Recording Save Modes

## Recording Save Modes 1 {#p1}

When you save a .jproxy recording, choose Recording Fidelity to control how much body data is kept in the file. This is separate from Long Capture Storage, which only affects live in-memory capture.

## Recording Save Modes 2 {#p2}

JoesProxy compresses the selected recording content automatically. Compression does not remove headers, timing, or body bytes; the Recording Fidelity choice alone determines what is preserved. Current and older .jproxy formats are detected when opened, so there is no compression setting to manage.

## Recording Save Modes 3 {#p3}

Default. Best for reopening and deep debugging. Bodies are kept up to the per-body cap; larger bodies are truncated when saved.

## Recording Save Modes 4 {#p4}

Smallest files. Keeps headers, status, timing, and structure without bodies.

## Recording Save Modes 5 {#p5}

Keeps JSON, XML, playlists, manifests, and other readable text while omitting binary and media payloads.

## Recording Save Modes 6 {#p6}

Keeps manifests, playback metadata, init segments, and bounded media bodies for streaming investigation.

## Recording Save Modes 7 {#p7}

On reopen, the inspector shows explicit banners when a body was omitted or truncated by the selected save mode. See memlog/Research/RecordingSaveFidelityUserGuide.md for caps and mode selection guidance.

