# HLS validation workflow

Revision: 2026-11-11. Repository guide for validating HLS fixtures, `Map Remote` / `Map Local` routing, and external Apple HLS Tools conformance without conflating acceptance layers.

For full Apple HLS Tools reference documentation on a Mac with the package installed, read the local user guide at `/usr/local/share/doc/hlstools/msv/` and `/usr/local/share/doc/hlstools/msv/agents/SKILL.md` (do not copy proprietary Apple documentation into this repository).

## Three separate acceptance layers

Keep these layers distinct in tests, evidence artifacts, and handoffs:

1. **Proxy transport layer**: JoesProxy capture evidence proves that master playlists, child playlists (relative and absolute URIs), redirects, `206` byte-range requests, and media segments traversed JoesProxy with expected status codes, headers, response bytes, and rule attribution (`.mapRemote` / `.mapLocal`).
2. **HLS specification validation layer**: Offline fixture checks (`Fixtures/HLS/validate-six-second-sdr-profile.sh`) and external `mediastreamvalidator` + `msvsummary` findings for the configured validation scope.
3. **Player acceptance layer**: Actual playback, seeking, rendition switches, and subtitle selection in `AVPlayer`, Simulator, or physical devices. Validator conformance never establishes player playback or perceptual quality.

## Offline fixture validation (no external HLS Tools required)

- Positive-control VOD fixtures live under `Fixtures/HLS/sdr-six-second-positive-v1` and `Fixtures/HLS/baseline-aligned-codecs` (see `Fixtures/HLS/README.md`).
- Verify bitstream timestamps, codecs, and playlist shapes offline with:

```bash
./Fixtures/HLS/validate-six-second-sdr-profile.sh
```

- Proxy transport + HLS VOD loopback parity is covered in `JoesProxyTests/LoopbackDestinationPolicyTests.swift` (`testHLSVODDirectVersusLoopbackMapRemoteProxyControl`).

## Apple HLS Tools (`mediastreamvalidator` & `msvsummary` `2.0.284-260930`)

Installed binary paths on configured Macs: `/usr/local/bin/mediastreamvalidator` and `/usr/local/bin/msvsummary` (`/usr/local/bin/hlsreport` is legacy 1.x only).

- **Prefer 3.x JSON + `msvsummary`**: `mediastreamvalidator` `2.0.x` emits version `3.x` JSON by default (`--validation-data-path <path>` / `-O <path>`, default `validation_data.json`). Render human and compact Markdown summaries with:

```bash
msvsummary <dir>/validation_data.json
msvsummary --format markdown --detail summary -o <dir>/summary.md <dir>/validation_data.json
```

- **Do not mix 1.x `hlsreport` output with `msvsummary`**: Passing `--compatible-output=full` emits legacy `1.x` JSON for `hlsreport` and makes `validation_data.json` unreadable by `msvsummary` unless `v3.x` is specified.
- **Gate on `mediastreamvalidator --exit-code.threshold`, never on `msvsummary`**:
  - `mediastreamvalidator` defaults `--exit-code.threshold` to `none` (exits `0` even when errors are found), and `msvsummary`'s exit code (`0` report produced, `2` unreadable file) says nothing about stream compliance. Gate validation on `mediastreamvalidator --exit-code.threshold must` (or `must_auth` if authoring-only `4xxxxx` findings should fail; valid lowercase levels: `advisory`, `should_auth`, `must_auth`, `should`, `must`, `critical`, `failure`, or `1`–`7`). Note that `msvsummary` groups both `Must` (`5xxxxx`) and `Must_Auth` (`4xxxxx`, e.g., `433088` `CLOSED-CAPTIONS=NONE` on `sdr-six-second-positive-v1`) under its `"MUST Fix Authoring Issues"` heading even though `--exit-code.threshold must` gates strictly at severity `5+`.
  - `mediastreamvalidator` exits `-3` when findings meet or exceed the threshold (`0` pass, `-1` internal error, `-2` configuration error) AND inspect parsed `validation_data.json` findings directly (`validation_data.json` missing or truncated is never a pass). Finding IDs are 6-digit `LCSIJK` integers (`L` prefix `1` Advisory through `7` Failure).
- **Bound execution time and media scope**:
  - Default `--timeout` is `300` seconds (infinite under `--continuous-output`). Pass an explicit `--timeout <seconds>` and `--limit.video` / `--limit.audio` when needed.
  - Use `-p` (`--parse-playlist-only`) with `--timeout none` only for fast playlist-structure checks; parse-only skips segments and does not validate delivery.
- **Direct-vs-remapped Map Remote contract**:
  - Keep artifacts under gitignored `build/` (for example `build/hls-validation/<timestamp>/`), separated into direct-origin and JoesProxy-remapped subdirectories.
  - `mediastreamvalidator` (`2.0.284`) uses CFNetwork/`NSURLSession` and **ignores POSIX `http_proxy` / `HTTP_PROXY` environment variables** (using `http_proxy` fails DNS with `751032` / `-1003` and logs zero proxy sessions). Route `mediastreamvalidator` through JoesProxy either via **macOS System Web Proxy** (interactive/human-approved network setup for virtual hosts) or by pointing `http://127.0.0.1:<proxyPort>/master.m3u8` at JoesProxy's origin-form HTTP handler with a Map Remote rule matching `127.0.0.1:<proxyPort>` -> `127.0.0.1:<originPort>` (automated under `TEST_RUNNER_JOESPROXY_RUN_EXTERNAL_HLS_VALIDATOR=1` in `LoopbackDestinationPolicyTests`). Always verify from JoesProxy capture attribution that playlists and segments traversed `.mapRemote`.
  - Archive tool version (`mediastreamvalidator --version` writes to stderr), exact CLI arguments, active rule IDs, fixture digest, 3.x `validation_data.json`, `msvsummary` HTML/Markdown reports, and JoesProxy session attribution.
