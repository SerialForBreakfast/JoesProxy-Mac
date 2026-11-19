# Max Mini • build 26 acceptance rerun

Use the signed 1.9.1 (26) kit already in this folder. Its accepted DMG SHA-256 is
`394948860d3ef0049b791abde3e19cf867bbf1f1bafd1664261e2a546e4d7545`.
The new `waterfall-build26.jproxy` is a separate offline recording. Its only
host is the reserved `hls.example.test`. All retained bodies come from the
repository’s generated six-second SDR AVC/AAC fixture. Opening the recording
requires no origin server, network routing change, or trusted root.

## Unblock the host

1. Check free space again. The previous reading was 3.7 GiB and the local UI
   runner requires at least 5 GiB. Allow room beyond that for installation,
   recordings and results. Have the owner move or remove approved items if
   needed, or use a suitable test volume/account. Record the new free space.
2. Preserve the build 25 baseline before upgrading: saved recording, CA
   fingerprint, enrolled-client identity and existing proxy configuration.
   Install the verified build 26 from the original kit, eject the DMG, launch
   from Applications, and verify About and the installed CLI both say 1.9.1 (26).
   Test the seeded public 1.9.0 upgrade and fresh-account install separately.
3. For destructive cleanup, arrange a disposable login, a test-only CA and
   enrollment, and a test network location with known working prior proxy
   settings. Preserve the real upgrade account. The offline waterfall check
   can proceed while the cleanup environment is being prepared.

## Open the recording and check both waterfall entry points

Verify the supplemental files with `shasum -a 256 -c waterfall-build26.sha256`
in their folder. Save existing work, then choose **File → Open Recording** and
**Replace** in the test session. Expect four fixture requests plus any lifecycle
marker the app adds. The first playlist deliberately has no response.

| Captured request | Session ID |
|---|---|
| Pending 360p playlist, no response | `00000026-0000-4000-8000-000000000001` |
| Gzipped HLS master | `00000026-0000-4000-8000-000000000002` |
| Completed 720p media playlist | `00000026-0000-4000-8000-000000000003` |
| Captured 720p MPEG-TS segment | `00000026-0000-4000-8000-000000000004` |

Open Media Info → Waterfall first from the master, then from the segment.
From the installed app’s CLI with an enrolled client on the test endpoint,
run these reads, supplying your configured endpoint if different from default:

```sh
cli=/Applications/JoesProxy.app/Contents/MacOS/joesproxyctl
"$cli" doctor --json
"$cli" media waterfall --session-id 00000026-0000-4000-8000-000000000002 --json
"$cli" media waterfall --session-id 00000026-0000-4000-8000-000000000004 --json
"$cli" capture digest --json
```

For both waterfall targets, expect **HLS Master Playlist**, ladder bandwidths
**249082, 310996, 374666 bit/s**, and **one segment**, ending in **0004**.
Record elapsed time and confirm the window and subsequent digest respond.
If a call hangs, record the entry point, ID and elapsed time before retrying.

The import only establishes behavior on recorded data. For live acceptance,
start capture in the disposable setup, play a stream you control, record its
latest capture sequence, run a waterfall on a captured playlist or segment,
and request the digest again during playback. Verify new successful playlist
or segment requests appear after the waterfall. Report this separately.

## Finish the remaining build 26 gates

Use the original kit’s SECOND-MAC.md for the 303-request recording, before
and after save/reopen. Check the two inclusive windows (299 then 300 HTTP
502s, one missing status each), and both same-endpoint comparisons: the
recorded Boolean/date change and the live Boolean true versus string "true".
Verify upgrade continuity, Keychain Allow once and Deny, default-trust HTTPS
inspection, bypass, authorized routing and deactivation. Finally follow the
DMG’s uninstall guide in the disposable context. Verify restoration of the
original network settings and browsing, retirement of the exact test identity
and client, and survival of a saved recording through reinstall.

Please post a new dated acceptance reply in MaxMini. Include build, DMG and
recording hashes, macOS, installation baseline, and PASS/FAIL/BLOCKED per gate.
Report the first unexpected observation and which steps remain. Omit private
endpoints, credentials, and raw traffic. The artifact checks from the previous
report remain valid for the same DMG hash.
