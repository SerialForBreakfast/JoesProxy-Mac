#!/usr/bin/env python3
"""Provisional, real-time console <-> JoesProxy wire correlation.

Usage:
  correlate_live.py <console.log> [--grep PATTERN] [--endpoint URL] [--since-sequence N]
                     [--reorder-window SECONDS] [--redact]

--redact is OFF by default (see redact.py) — scrubs common secret shapes (JWTs, bearer tokens,
sensitive key=value pairs) from what's printed. Off by default so live observation isn't silently
missing detail; turn it on if this live output itself will be shared as-is.

This is the live-observation companion to correlate_batch.py, not a replacement for it. Output is
explicitly labeled PROVISIONAL: two independently-delayed sources cannot guarantee immediately
correct ordering, so events are held in a short reorder window (default 1.5s) before being
flushed, and anything that still arrives after its window already flushed is printed with a
[late-arrival] tag rather than silently reordered in place. After reproducing the issue, stop this
script and run `correlate_batch.py` once over the same console-log file for the canonical,
fully-drained, epoch-safe transcript.

Wire updates are driven by `joesproxyctl watch capture --ndjson` (SSE-backed) as the primary
wake-up signal; a plain ~2s poll of `capture digest` is used only as a reconnect fallback if the
watch subprocess exits or goes quiet.
"""
from __future__ import annotations

import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

import normalize
import redact
from correlate_batch import fetch_all_wire_events

WATCH_TIMEOUT_SECONDS = 300  # joesproxyctl's own --timeout ceiling is 300s; we respawn on exit.
POLL_FALLBACK_SECONDS = 2.0
WATCH_QUIET_FALLBACK_SECONDS = 8.0


class ConsoleTailer:
    """Polls a growing file for newly-appended lines, tolerating the file not existing yet."""

    def __init__(self, path: str, pattern: str | None):
        self.path = path
        self.pattern = re.compile(pattern, re.I) if pattern else None
        self._pos = 0
        self._seeked_to_end = False

    def read_new_lines(self) -> list[str]:
        try:
            with open(self.path, errors='replace') as f:
                if not self._seeked_to_end:
                    # Start from the current end of the file — this is a live-follow, not a replay
                    # of everything captured before the script started.
                    f.seek(0, 2)
                    self._pos = f.tell()
                    self._seeked_to_end = True
                    return []
                f.seek(self._pos)
                lines = f.readlines()
                self._pos = f.tell()
        except FileNotFoundError:
            return []
        if self.pattern:
            lines = [ln for ln in lines if self.pattern.search(ln)]
        return [ln.rstrip('\n') for ln in lines if ln.strip() and not ln.startswith('#')]


class WireWatcher:
    """Wraps `joesproxyctl watch capture` as the primary wake signal, with a quiet-timeout and
    process-exit reconnect, plus a periodic poll fallback."""

    def __init__(self, endpoint: str):
        self.endpoint = endpoint
        self._proc: subprocess.Popen | None = None
        self._last_signal = time.monotonic()

    def _ensure_running(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            return
        self._proc = subprocess.Popen(
            ['joesproxyctl', 'watch', 'capture', '--ndjson', '--endpoint', self.endpoint,
             '--timeout', str(WATCH_TIMEOUT_SECONDS)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self._last_signal = time.monotonic()

    def stop(self) -> None:
        """Terminate exactly this script's own watch-capture child, nothing else. Always call
        this before exiting — an un-reaped child otherwise keeps running indefinitely."""
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait(timeout=3)

    def poll_for_signal(self) -> bool:
        """Returns True if the caller should re-fetch wire events now: either the watch stream
        emitted a change notification, or the quiet-timeout/poll-fallback interval elapsed."""
        self._ensure_running()
        assert self._proc is not None and self._proc.stdout is not None
        # Non-blocking-ish drain: readline() would block if nothing is buffered, so only attempt
        # it when the OS reports data is available.
        import select
        got_signal = False
        while True:
            ready, _, _ = select.select([self._proc.stdout], [], [], 0)
            if not ready:
                break
            line = self._proc.stdout.readline()
            if line == '':
                break  # subprocess closed its stdout; will be respawned next _ensure_running()
            got_signal = True
            self._last_signal = time.monotonic()
        if got_signal:
            return True
        quiet_for = time.monotonic() - self._last_signal
        if quiet_for >= WATCH_QUIET_FALLBACK_SECONDS:
            self._last_signal = time.monotonic()
            return True  # reconnect fallback: poll anyway even without a watch signal
        return False


def main() -> None:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    console_path = args[0]
    endpoint = 'http://127.0.0.1:9091/mcp'
    pattern = None
    since_sequence = 0
    reorder_window = 1.5
    do_redact = False  # off by default — see redact.py's module docstring for why
    i = 1
    while i < len(args):
        if args[i] == '--grep':
            pattern = args[i + 1]; i += 2
        elif args[i] == '--endpoint':
            endpoint = args[i + 1]; i += 2
        elif args[i] == '--since-sequence':
            since_sequence = int(args[i + 1]); i += 2
        elif args[i] == '--reorder-window':
            reorder_window = float(args[i + 1]); i += 2
        elif args[i] == '--redact':
            do_redact = True; i += 1
        else:
            i += 1

    print("===== PROVISIONAL LIVE TIMELINE =====")
    print("# Not the canonical record — run correlate_batch.py after capture ends for that.")
    print(f"# reorder window: {reorder_window}s; wire endpoint: {endpoint}; redact: {'on' if do_redact else 'off (default)'}")
    print("======================================")

    tailer = ConsoleTailer(console_path, pattern)
    wire_watcher = WireWatcher(endpoint)
    known_epoch: str | None = None
    seq = since_sequence
    pending: list[normalize.Event] = []
    last_flushed_key: datetime | None = None
    last_poll = 0.0

    def on_epoch_boundary(old_epoch: str | None, new_epoch: str | None) -> None:
        print(f"===== CAPTURE EPOCH BOUNDARY: {old_epoch} -> {new_epoch} =====")

    # `kill <pid>` sends SIGTERM, not SIGINT — without this handler, only Ctrl-C would trigger
    # cleanup, and the watch-capture child would be silently orphaned on any other termination.
    def _handle_sigterm(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, _handle_sigterm)

    try:
        while True:
            for line in tailer.read_new_lines():
                if line.lstrip().startswith('{'):
                    pending.append(normalize.parse_simulator_ndjson_line(line))
                else:
                    pending.append(normalize.parse_idevicesyslog_line(line))

            now = time.monotonic()
            should_fetch_wire = wire_watcher.poll_for_signal() or (now - last_poll) >= POLL_FALLBACK_SECONDS
            if should_fetch_wire:
                last_poll = now
                # `known_epoch` is threaded through explicitly here — and updated from the
                # return value below — specifically so a JoesProxy restart between two polls
                # (not just mid-drain within one poll) is still detected as a boundary.
                new_events, latest, known_epoch = fetch_all_wire_events(
                    endpoint, seq, on_epoch_boundary, known_epoch
                )
                if new_events:
                    seq = latest
                    pending.extend(new_events)

            # Flush anything old enough to have cleared the reorder window.
            cutoff = datetime.now(timezone.utc).timestamp() - reorder_window
            ready = [e for e in pending if e.orderingKey().timestamp() <= cutoff]
            pending = [e for e in pending if e.orderingKey().timestamp() > cutoff]
            ready.sort(key=lambda e: e.orderingKey())
            for e in ready:
                late = last_flushed_key is not None and e.orderingKey() < last_flushed_key
                late_tag = ' [late-arrival]' if late else ''
                degraded_tag = ' [degraded]' if e.parseStatus == 'degraded' else ''
                t = e.orderingKey().strftime('%H:%M:%S.%f')[:-3]
                kind = 'APP ' if e.sourceType == 'app' else 'WIRE'
                text = redact.redact_text(e.raw)[0] if do_redact else e.raw
                print(f"{t}  {kind}  {text}{degraded_tag}{late_tag}", flush=True)
                if last_flushed_key is None or e.orderingKey() > last_flushed_key:
                    last_flushed_key = e.orderingKey()

            time.sleep(0.3)
    except KeyboardInterrupt:
        print("\n# stopped. Run correlate_batch.py now for the canonical transcript.")
    finally:
        # Always reached — normal exit, KeyboardInterrupt, or any other exception — so the
        # watch-capture child is never left running after this script exits.
        wire_watcher.stop()


if __name__ == '__main__':
    main()
