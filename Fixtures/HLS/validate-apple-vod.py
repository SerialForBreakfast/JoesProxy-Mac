"""Run Apple's full-media validator against the shipped synthetic VOD matrix."""
import functools
import json
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent
# Apple HLS Tools 2.0.284. Keep lower-severity bitrate regressions visible too.
CAPTIONS = {242528}
BASELINE = CAPTIONS | {135042}
CASES = {
    "sdr-six-second-positive-v1": (60, 60, CAPTIONS),
    "baseline-aligned-codecs": (26, 26, BASELINE),
    "player-qa-widescreen-v1": (42, 42, CAPTIONS),
    "missing-codecs-only": (26, 26, BASELINE),
    "bogus-ad-alias-only": (19, 19, BASELINE),
    "misaligned-audio-boundary": (30, 30, BASELINE | {536009}),
    "discontinuity-cross-rendition-drift": (30, 30, BASELINE | {536001, 536002, 536009}),
    "combined-defects": (21, 0, CAPTIONS | {111025, 536001, 536009}),
}


class FixtureHandler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map,
                      ".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t"}

    def log_message(self, format, *args):
        pass


def validate(profile, origin, output):
    parsed, processed, required = CASES[profile]
    report = output / (profile + ".json")
    args = ["mediastreamvalidator", "--timeout", "60", "--exit-code.threshold",
            "must_auth", "-O", str(report), f"{origin}/{profile}/master.m3u8"]
    with (output / (profile + ".log")).open("w") as log:
        print(args, file=log, flush=True)
        run = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=75)
    data = json.loads(report.read_text())
    codes = {int(code) for code in data["messages"]}
    media = [node["details"] for node in data["structure"]["M01"].values()
             if isinstance(node, dict) and node.get("details", {}).get("playlistKind") == "media"]
    counts = [(item["parsedSegmentsCount"], item["processedSegmentsCount"]) for item in media]
    totals = (sum(p for p, _ in counts), sum(n for _, n in counts))
    directory = ROOT / profile
    lines = (directory / "master.m3u8").read_text().splitlines()
    playlists = {line for line in lines if line and not line.startswith("#")}
    for line in lines:
        if line.startswith("#EXT-X-MEDIA:"):
            playlists.update(re.findall(r'\bURI="([^"]+)"', line))
    expected_counts = {path: (directory / path).read_text().count("#EXTINF:") for path in playlists}
    observed_counts = {item["url"]: item["parsedSegmentsCount"] for item in media}
    expected_exit = 253 if any(code >= 400000 for code in required) else 0
    ok = (totals == (parsed, processed) and run.returncode == expected_exit
          and codes == required and observed_counts == expected_counts
          and all(p > 0 and n == (p if processed else 0) for p, n in counts))
    print(f"{profile}: {totals[1]}/{totals[0]} processed, exit {run.returncode}, "
          f"findings {sorted(codes)}, expectation {'met' if ok else 'FAILED'}", flush=True)
    return ok


def main():
    evidence = ROOT.parents[1] / "build" / "hls-validation"
    evidence.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="apple-vod-", dir=evidence))
    print(output, flush=True)
    handler = functools.partial(FixtureHandler, directory=str(ROOT))
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            results = []
            for profile in CASES:
                try:
                    results.append(validate(profile, f"http://127.0.0.1:{server.server_port}", output))
                except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
                    print(f"{profile}: incomplete validation: {error}", flush=True)
                    results.append(False)
        finally:
            server.shutdown()
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
