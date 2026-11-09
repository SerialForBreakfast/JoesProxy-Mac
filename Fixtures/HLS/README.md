# JoesProxy HLS test fixtures

## Multilingual text VOD — 2026-09-21

`multilingual-text-vod-v1/profile.json` is the editable text contract. It contains seven bounded
diagnostic tracks, cue times, source revision/provenance and a pinned inventory digest for the
existing `player-qa-widescreen-v1` media. `HLSWebVTTFixture` deterministically prepares the actual
master, seven subtitle playlists and 42 WebVTT segments before routing starts. The checked-in
master is a discovery marker, **not** a standalone playable playlist. Use the JoesProxy fixture
server; do not host this directory with an ordinary static server.

Preparation verifies base-file hashes and retains only shared media paths, not duplicate binaries.
All three video renditions were inspected with the installed `ffprobe`: first video PTS is 132000
at 90 kHz. The WebVTT map binds cue time zero to that timestamp. The 24-second video timeline is
the text anchor. Explicit conformant `liveLoop` supports off/warmDVR/coldDVR using the same
publication epoch, uniform four-second grid and discontinuities for video and text. AAC retains
its real packet durations; the pinned pack permits at most 20 ms boundary skew and an exact
shared cycle duration. VOD remains
the default. JIT, legacy implicit-live and deliberate-fault text configurations reject.

Each loop repeats the precompiled cue bytes with a matching media timestamp reset and declared
discontinuity; timestamps are not continually advanced toward the 33-bit wrap boundary. Sequence
URLs identify logical intervals while ETags describe reused bytes. Rolling requests obey the
shared retention window. Completion freezes publication; prior-phase assets remain available
until the owning run stops. Prepared replacements publish at a shared cycle boundary and must
preserve the compiled master and each rendition's grid exactly, including track metadata and
declared bandwidth. Unsupported topology changes reject.

The text pack uses English/Spanish/French, English SDH/forced and Arabic/Japanese script samples.
Translations are diagnostic and unreviewed; audio consists of synthetic tones, not translated
speech. To edit: preserve valid language/name/role metadata, cue order and bounds, then run the
`HLSWebVTTFixtureTests`, fixture matrix and MCP lifecycle tests. Changing base media requires an
intentional review of its inventory digest and timestamp map. No encoding or download happens
at runtime. Generated text uses stable ETags, HEAD and single-range serving.

Visible selection, forced-track policy, Unicode rendering and synchronization remain host/player
acceptance gates. Passing fixture/transport tests does not establish those outcomes.

Deterministic, checked-in HLS content used by `HLSFixtureServer` (see `JoesProxy/MediaFixture/`) to
give an MCP/CLI agent a self-hosted HLS source for CODECS/AD/discontinuity experiments — no live
capture, no physical device, no runtime `ffmpeg` dependency. Design context:
`memlog/Research/HLS-CODECS-Testing-Roadmap.md` ("Phase 2").

## Layout

Each profile is a directory under `Fixtures/HLS/<profile-name>/`:

```text
<profile-name>/
  master.m3u8            hand-assembled master playlist (variants + audio renditions)
  video-lo/               640x360  ~800k H.264, VOD-shaped HLS (stream.m3u8 + seg-NNN.ts)
  video-hi/               960x540 ~1400k H.264, VOD-shaped HLS
  audio-en/               English program audio, AAC, 440Hz sine tone
  audio-ad/               English Audio Description audio, AAC, 880Hz sine tone (present unless the
                           profile intentionally omits it)
  audio-es/               Spanish-labelled synthetic audio (profiles that exercise language selection)
  audio-de/               German-labelled synthetic audio (profiles that exercise language selection)
  keys/                   (key-rotation / combined only) nonsecret test key files
  expected-hashes.json    sha256 + byte count per file, for automated content-verification tests
```

`HLSFixtureServer` treats each profile's segment set as fixed content and computes a sliding
playlist window over it at serve time (rolling `EXT-X-MEDIA-SEQUENCE`) — the files here are static,
authored once; nothing about serving them is real-time encoding.

### HF-0 runtime baseline

All checked-in `stream.m3u8` files are authored as finite VOD playlists. The compatibility server
currently parses those files once, discards their VOD/`EXT-X-ENDLIST` presentation markers, and
publishes a four-entry, forward-looking diagnostic window beginning with the segment selected by
elapsed time. The query parameter used for a conformant virtual occurrence changes URI identity,
not media bytes: removing `jp_hls_sequence` addresses the same immutable checked-in segment.

This four-entry output is useful for fast stress experiments, but it is not the Apple-guideline
positive control planned by Workstream HF. Existing profile IDs and default MCP/CLI behavior retain
this shape as an explicit compatibility mode while `vodStatic` and trailing `liveLoop` publication
are introduced separately.

New direct fixture runs can select their presentation explicitly:

```bash
joesproxyctl hls fixture prepare-start --profile-id <id> --presentation-mode vodStatic
joesproxyctl hls fixture prepare-start --profile-id <id> --presentation-mode liveLoop
```

`vodStatic` serves the authored rendition playlist byte-for-byte and ignores elapsed time.
`liveLoop` starts with a warm trailing history and adds a segment only after its full authored
duration has elapsed. Omitting `--presentation-mode` preserves the original compatibility output.

### HF-3 bounded live time shifting

Live time shifting is separate from Low-Latency HLS. A `liveLoop` run can select `off`, `warmDVR`,
or `coldDVR`: warm mode exposes a full trailing window immediately, while cold mode begins empty
and grows only as complete segments publish. Selecting warm or cold mode without an explicit
window uses the bounded 15-entry smoke setting; the six-second positive-control profile therefore
advertises about 90 seconds.

```bash
joesproxyctl hls fixture prepare-start --profile-id sdr-six-second-positive-v1 \
  --presentation-mode liveLoop --time-shift-mode warmDVR --window-segments 15
```

Custom windows are bounded to 2–30 entries and rendered playlists to 64 KiB. Existing fixture-run
TTL and per-client active-run quotas remain hard lifecycle bounds. Unique virtual segment URLs are
available while advertised and for a deterministic post-eviction grace equal to at least the
segment duration plus the longest playlist duration that contained it; expired virtual URLs return
404 for the remainder of the run. The immutable source asset without `jp_hls_sequence` remains
available until Stop or run expiry.

`hls fixture window-preview` reports JoesProxy wire evidence for each rendition: oldest advertised
and newest published sequence, earliest program time, live-edge time, advertised duration, and the
oldest retained-but-evicted sequence. It does not claim player-observed seekability or playback
state; record those separately with the guided validation in
`memlog/Research/HLS-Live-Time-Shifting-Player-Validation.md`.

The JoesProxy app includes the repo-root `Fixtures/` folder as a **Copy Bundle Resources**
folder reference, so profiles land at `Bundle.main.../Fixtures/HLS` for
`HLSFixtureRunStore` discovery without relying on repo CWD.

## Generation (offline developer adapter)

**Preferred entry point:** `author-hls.sh` (P2-optional packaging). CI, unit tests, MCP, and
`HLSFixtureServer` never invoke these scripts.

```bash
cd Fixtures/HLS
./author-hls.sh preflight                 # jq, rsync, shasum, ffmpeg — fail clearly, never auto-install
./author-hls.sh preflight --skip-ffmpeg   # playlist-only workflows
./author-hls.sh baseline                  # encode baseline-aligned-codecs + emit hashes
./author-hls.sh player-qa                 # encode the recommended widescreen player-QA profile
./author-hls.sh sdr-six-second            # encode the 90s nominal-six-second SDR positive control
./author-hls.sh validate-sdr-six-second   # rerun bounded ffprobe checks without regenerating media
./author-hls.sh matrix                    # full matrix (ffmpeg for misaligned audio)
./author-hls.sh matrix --skip-ffmpeg      # playlist-only refresh; reuse existing misaligned audio
./author-hls.sh matrix --only key-rotation-only
./author-hls.sh regenerate-all            # baseline then full matrix
./author-hls.sh hashes <profile-dir> --purpose "..." [--differs "..."]
```

Install `ffmpeg` yourself (e.g. Homebrew) when you need to encode or regenerate misaligned audio.
This repository never auto-installs tools.

Underlying scripts (still usable directly):

- `generate-profile.sh <profile-dir> [--no-codecs] [--no-ad] [--bogus-ad] [--discontinuity]` —
  offline ffmpeg authoring of a full profile from scratch (used for baseline).
- `materialize-matrix.sh [--skip-ffmpeg] [--only <id>]` — copies baseline media and applies
  matrix deltas; regenerates misaligned audio with ffmpeg unless `--skip-ffmpeg`.
- `emit-expected-hashes.sh` — writes `expected-hashes.json` (`--generated-with`, optional
  `--ffmpeg-version` for provenance). Shared helpers live in `_lib.sh`.

Most matrix profiles **reuse** `baseline-aligned-codecs` video/audio bytes and only differ in
playlists (or add `keys/`). `misaligned-audio-boundary` and `combined-defects` regenerate audio
on a 3s segment grid.

## Profile matrix

Every current rendition playlist is authored as finite VOD and every current audio track is a
separate URI-backed AAC rendition. At runtime, the unchanged profile ID can be presented through
legacy sliding-live compatibility, exact `vodStatic`, or trailing `liveLoop`; presentation mode
does not alter the inventoried source bytes. “Bundle bytes” is the sum governed by that profile's
`expected-hashes.json`, excluding the hash manifest itself.

| Profile | Segment grid | Class / controlled fault | Audio topology | Bundle bytes | Hash reuse |
|---|---|---|---|---:|---|
| `baseline-aligned-codecs` | ~4s aligned A/V | Positive control: complete `CODECS`, distinct AD, aligned splices | Demuxed program + AD | 3,492,647 | Canonical baseline media |
| `missing-codecs-only` | ~4s aligned A/V | Fault: variant `CODECS` omitted | Demuxed program + AD | 3,492,585 | Baseline media; master differs |
| `bogus-ad-alias-only` | ~4s aligned A/V | Fault: advertised AD URI aliases program audio | Demuxed labels; aliased AD bytes | 3,492,647 | Baseline media; master differs |
| `discontinuity-at-switch` | ~4s aligned A/V | Fault probe: aligned discontinuity before entry 3 | Demuxed program + AD | 3,492,731 | Baseline media; rendition playlists differ |
| `key-rotation-only` | ~4s aligned A/V | Fault probe: tag-only key rotation over clear segments | Demuxed program + AD | 3,493,979 | Baseline media plus nonsecret keys |
| `misaligned-audio-boundary` | ~4s video / ~3s audio | Fault: cross-grid switching | Demuxed program + AD | 3,495,019 | Baseline video; regenerated audio |
| `combined-defects` | ~4s video / ~3s audio | Fault: missing `CODECS`, AD alias, discontinuity, key tags, and grid mismatch | Demuxed labels; aliased AD path | 3,496,573 | Baseline video plus misaligned audio and keys |
| `discontinuity-cross-rendition-drift` | ~4s video / ~3s audio | Fault: rendition-specific discontinuities at video 3, program 5, AD 4 | Demuxed program + AD | 3,495,103 | Misaligned media; playlists differ |
| `param-aligned-4s` | ~4s aligned A/V | Parameterized positive control | Demuxed program + AD | 3,492,647 | Byte-identical baseline copy |
| `param-cross-disc-v3-aen5-aes4` | ~4s video / ~3s audio | Parameterized rendition-discontinuity fault | Demuxed program + AD | 3,495,103 | Byte-identical cross-rendition copy |
| `param-lang-en-es` | ~4s aligned A/V | Language-label selection control; not translated speech | Demuxed program + relabeled alternate | 3,492,760 | Baseline media; alternate reuses program bytes |
| `param-misaligned-v4-a3` | ~4s video / ~3s audio | Parameterized cross-grid fault | Demuxed program + AD | 3,495,019 | Byte-identical misaligned copy |
| `player-qa-widescreen-v1` | ~4s aligned A/V | Positive player control: 360p/720p/1080p ABR and four distinct synthetic audio signatures | Demuxed program + AD + two language-labelled alternates | 9,285,383 | Independently authored media |
| `sdr-six-second-positive-v1` | 6s aligned A/V; 15 entries / 90s | Positive control: measured 360p/720p/1080p SDR AVC/AAC declarations and continuous live-time-shifting-ready source timeline | Demuxed synthetic program audio | 8,264,090 | Independently authored media |

Runtime inventory notes:

- The baseline-derived profiles use an approximately four-second video/audio grid, except the
  intentionally misaligned profiles whose audio grid is approximately three seconds.
- Audio is currently URI-backed AAC; muxed default audio and hybrid/JIT topology are not yet
  represented by checked-in media.
- Controlled faults are manifest/key/grid/discontinuity variants over bounded, deterministic
  content. They do not invoke runtime encoding.
- `expected-hashes.json` records bundle bytes and hash reuse; the profile-matrix tests enforce the
  inventory and prevent a profile ID from silently acquiring different media.
- No current profile contains muxed default audio, hybrid/JIT audio, ID3, HDR, EVENT, LL-HLS, or a
  mutable producer. Those remain later HF slices or explicitly deferred work.

Profiles may include `profile.json` with human-readable purpose, feature tags, rendition metadata,
audio rendition details, audio description, and recommendation status. The language tracks use
distinct synthetic signatures rather than spoken recordings, so selection is unambiguous without
adding third-party media or licensing obligations. Legacy profiles without metadata remain discoverable and
receive a deterministic fallback descriptor.

### Parameterized profiles (`author-param-profile.sh`)

Byte-for-byte `rsync` aliases/relabels of the profiles above — no new ffmpeg encode, only a
different `master.m3u8` and/or directory naming, kept as distinct profile IDs so they're
independently selectable. `HLSFixtureRunStore.availableProfiles()` discovers these identically to
the core profiles above (any subdirectory containing `master.m3u8` is a valid profile — there is no
naming-convention filter).

| Profile | Source (byte-identical copy of) | Purpose |
|---|---|---|
| `param-aligned-4s` | `baseline-aligned-codecs` | Named alias for parameterized-test readability. |
| `param-misaligned-v4-a3` | `misaligned-audio-boundary` | Named alias (v=4s video grid, a=3s audio grid). |
| `param-cross-disc-v3-aen5-aes4` | `discontinuity-cross-rendition-drift` | Named alias (v=disc@3, audio-en=disc@5). |
| `param-lang-en-es` | `baseline-aligned-codecs`, with `audio-es` a **relabeled copy of `audio-en`'s bytes** (not a real Spanish recording) and `audio-ad` removed | Language-switch testing where only the manifest's `LANGUAGE` attribute differs, not the audio content. |

## Verification

`expected-hashes.json` per profile is what `HLSFixtureProfileMatrixTests` checks against — no
`ffprobe` or other media-tooling dependency at test time, just SHA-256 comparison. Sliding playlist
output is verified at a fixed injected clock, never as a single timeless manifest hash.

Provenance fields `generatedWith` and optional `ffmpegVersion` are recorded for regeneration
recipes; inventory SHA checks ignore those metadata keys beyond requiring `generatedWith` when present.

## Revision history

- 2026-08-26: Recorded the HF-0 runtime compatibility baseline, current profile topology, and the
  boundary between immutable fixture bytes and explicit VOD/live publication modes; documented
  direct CLI selection after completing the first HF-1 lifecycle slice. Added the project-authored
  90-second, nominal-six-second SDR AVC/AAC positive control for HF-2.
