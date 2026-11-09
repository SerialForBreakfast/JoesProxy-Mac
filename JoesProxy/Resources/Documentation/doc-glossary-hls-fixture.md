# HLS Fixture

## Definition {#definition}

A local synthetic HLS stream served by JoesProxy and optionally redirected onto a real host path via Map Local. Bounded live time shifting uses warm or cold DVR modes and is unrelated to Low-Latency HLS (LL-HLS).

Revision 2026-09-21: **Multilingual Captions** (`multilingual-text-vod-v1`) adds seven
WebVTT text choices: English, Spanish, French, English SDH, English forced-only, Arabic and Japanese.
It reuses the existing 24-second test pattern and synthetic tones; the text is original diagnostic
material, not reviewed localization or translated speech. Every displayed cue includes a language,
role and cue identifier. The interval from 8–12 seconds intentionally contains no cues.

Discover tracks with `hls_fixture_profiles_list` or `hls_substitution_profiles_list`. This profile
defaults to `playbackConfiguration.presentationMode=vodStatic` when configuration is omitted;
explicit conformant `liveLoop` also supports off, warmDVR and coldDVR. JIT text and deliberately
nonconformant text configurations reject. Existing profiles retain their defaults.
UI selection starts VOD; live configuration is available through reviewed fixture/substitution
operations. Normal approval and routing requirements
still apply; discovery does not start a fixture or grant mutation authority.

For a language test, select the profile, review/start through the existing fixture or substitution
workflow, then have the authorized player operator select Off → English → Spanish → French → Off.
Compare the visible cue ID and media time. Test SDH and forced choices separately: player
preferences may still select forced cues when full subtitles are off. CUE-002 spans 3.5–5.5 seconds
and is repeated in both intersecting segments without clipping its timestamps. Transport delivery
does not prove which track was selected or rendered; cached/prefetched text may require no new
request on a switch. Record any visible result with its external evidence source, then stop the
owned run and verify cleanup.

For live switching, explicitly select `liveLoop` and warmDVR or coldDVR, review the scope and
activation, then ask the authorized player operator to switch languages near a four-second segment
boundary and a 24-second loop boundary. Seek within and outside the advertised DVR window. Compare
the selected language and cue identity with video time, not just the presence of a text request.
Text and video use one publication clock. Completion freezes every playlist; Stop ends delivery.
Prepared phase switches publish at a shared cycle boundary, preserve already-published URLs and
require unchanged track topology. AAC durations remain authored rather than rounded to video.

Bundle delivery observations include validated text-track ID, language, role and source revision.
Explicit before/after reports summarize at most eight track identities per resource from retained
receipts, with truncation and incomplete-coverage qualifications. These counts include playlist
prefetch and failed requests; they are not selection counts. UI, MCP and CLI use the same metadata.
Target confirmation remains separately sourced, not inferred from these summaries.

Players may localize or normalize a track's display name. When a player API exposes selection
metadata, identify the language and role (ordinary subtitles, SDH, or forced) rather than requiring
an exact match to the fixture's display label. Verify the selected option and the expected cue;
discovering a track is not proof that it decoded or rendered.

This is not embedded CEA-608/708 support. Automated player rendering acceptance remains separate.
If preparation reports changed
base media, inspect/rebuild the intended fixture assets; no substitute profile is selected silently.
