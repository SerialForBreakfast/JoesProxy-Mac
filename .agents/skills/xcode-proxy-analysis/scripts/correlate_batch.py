#!/usr/bin/env python3
"""Epoch-aware batch merge of a console-capture log with JoesProxy wire sessions.

Usage:
  correlate_batch.py <console.log> [--since-sequence N] [--grep PATTERN] [--window SECONDS]
                      [--endpoint URL] [--redact]

--redact is OFF by default (see redact.py) — pass it when this transcript will be saved, shared,
or pasted somewhere, so common secret shapes (JWTs, bearer tokens, sensitive key=value pairs) get
scrubbed. Off by default so a developer reading it locally isn't silently missing detail.

This is the canonical, reproducible evidence transcript for a capture window: it fully drains
JoesProxy's session pagination before advancing its cursor (so a busy capture can't cause skipped
sessions), tracks capture epoch alongside sequence (so a JoesProxy restart mid-capture is shown as
a visible boundary instead of silently misreading sequence numbers across it), and ends with a
completeness/limits summary instead of presenting a clean-looking but possibly-incomplete
transcript as if it were the full story.

Console lines are produced by scripts/capture_stream.sh in `sim` (Simulator NDJSON) or
`device-syslog`/`device-archive` (idevicesyslog syslog-style) mode; this script auto-detects which
by trying the JSON parse first and falling back to the syslog parse.
"""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone

import normalize
import redact
from normalize import Event


def joesproxyctl_sessions_page(endpoint: str, since_sequence: int, cursor: str | None) -> dict:
    args = [
        'joesproxyctl', 'sessions', 'list',
        '--endpoint', endpoint,
        '--since-sequence', str(since_sequence),
        '--limit', '100',
        '--projection', 'summary',
        '--json',
    ]
    if cursor:
        args += ['--cursor', cursor]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {'success': False, 'errorMessage': f'unparseable response: {out[:200]}'}


def fetch_all_wire_events(
    endpoint: str,
    since_sequence: int,
    on_epoch_boundary,
    known_epoch: str | None = None,
) -> tuple[list[Event], int, str | None]:
    """Fully drains pagination for the *current* capture epoch, restarting from sequence 0 in the
    new epoch if a boundary is detected — either mid-drain (multiple pages in this one call) or
    at the very start of this call (the epoch the *caller* last knew about, passed in as
    `known_epoch`, differs from what the server reports now). Cross-call persistence of the epoch
    is essential for a caller that polls repeatedly (correlate_live.py) — without it, a restart
    between two polls would never be detected, since each call would otherwise start blind.
    Returns (events, latest_sequence_seen, known_epoch) — callers that poll repeatedly must feed
    the returned `known_epoch` back in as next call's `known_epoch` argument."""
    events: list[Event] = []
    cursor = None
    seq = since_sequence
    latest_seen = since_sequence
    degraded = 0

    while True:
        page = joesproxyctl_sessions_page(endpoint, seq, cursor)
        if not page.get('success', False):
            print(f"# wire fetch error: {page.get('errorMessage', 'unknown error')}", file=sys.stderr)
            break
        payload = page['result']['payload']
        page_epoch = (payload.get('captureEpoch') or {}).get('rawValue')

        if known_epoch is not None and page_epoch != known_epoch:
            on_epoch_boundary(known_epoch, page_epoch)
            seq = 0
            cursor = None
            known_epoch = page_epoch
            continue  # re-issue the query from the start of the new epoch

        known_epoch = page_epoch
        for item in payload.get('items', []):
            ev = normalize.wire_event_from_session(item)
            if ev.parseStatus == 'degraded':
                degraded += 1
            events.append(ev)
        latest_seen = max(latest_seen, payload.get('latestSequence', latest_seen))
        cursor = payload.get('nextCursor') if payload.get('hasMore') else None
        if not cursor:
            break

    return events, latest_seen, known_epoch


def load_console_events(path: str, pattern: str | None) -> list[Event]:
    import re
    pat = re.compile(pattern, re.I) if pattern else None
    events: list[Event] = []
    with open(path, errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            if pat and not pat.search(line):
                continue
            if line.lstrip().startswith('{'):
                events.append(normalize.parse_simulator_ndjson_line(line))
            else:
                events.append(normalize.parse_idevicesyslog_line(line))
    return events


def main() -> None:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    console_path = args[0]
    since_sequence = 0
    endpoint = 'http://127.0.0.1:9091/mcp'
    pattern = None
    window = None
    do_redact = False  # off by default — see redact.py's module docstring for why
    i = 1
    while i < len(args):
        if args[i] == '--since-sequence':
            since_sequence = int(args[i + 1]); i += 2
        elif args[i] == '--grep':
            pattern = args[i + 1]; i += 2
        elif args[i] == '--window':
            window = float(args[i + 1]); i += 2
        elif args[i] == '--endpoint':
            endpoint = args[i + 1]; i += 2
        elif args[i] == '--redact':
            do_redact = True; i += 1
        else:
            i += 1

    boundaries: list[tuple[str, str]] = []

    def on_epoch_boundary(old_epoch: str | None, new_epoch: str | None) -> None:
        boundaries.append((old_epoch, new_epoch))

    console_events = load_console_events(console_path, pattern)
    wire_events, latest_sequence, _ = fetch_all_wire_events(endpoint, since_sequence, on_epoch_boundary)

    rows = console_events + wire_events
    rows.sort(key=lambda e: e.orderingKey())

    if window and rows:
        anchors = [e.orderingKey() for e in rows if e.sourceType == 'app']
        if anchors:
            rows = [
                r for r in rows
                if any(abs((r.orderingKey() - a).total_seconds()) <= window for a in anchors)
            ]

    # Capture-epoch boundaries have no timestamp of their own (a JoesProxy restart isn't a wire or
    # app event) — print them up front, in the order they were discovered, rather than guessing
    # where in the transcript they belong.
    for old_epoch, new_epoch in boundaries:
        print(f"===== CAPTURE EPOCH BOUNDARY: {old_epoch} -> {new_epoch} =====")

    prev: datetime | None = None
    degraded_count = 0
    private_sightings = 0
    redaction_count = 0
    for r in rows:
        t = r.orderingKey().strftime('%H:%M:%S.%f')[:-3]
        delta = f"+{(r.orderingKey() - prev).total_seconds():6.3f}" if prev else '       '
        degraded_tag = ' [degraded]' if r.parseStatus == 'degraded' else ''
        if '<private>' in r.raw:
            private_sightings += 1
        if r.parseStatus == 'degraded':
            degraded_count += 1
        text = r.raw
        if do_redact:
            text, n = redact.redact_text(text)
            redaction_count += n
        kind = 'APP ' if r.sourceType == 'app' else 'WIRE'
        print(f"{t} {delta}  {kind}  {text}{degraded_tag}")
        prev = r.orderingKey()

    app_count = sum(1 for r in rows if r.sourceType == 'app')
    wire_count = sum(1 for r in rows if r.sourceType == 'wire')
    print("")
    print("===== COMPLETENESS / LIMITS SUMMARY =====")
    print(f"app events:        {app_count}")
    print(f"wire events:       {wire_count}")
    print(f"degraded events:   {degraded_count} (unparseable timestamp; ordered by host-receipt time)")
    print(f"<private> sightings: {private_sightings} (redacted by the OS log source, not by this script)")
    if do_redact:
        print(f"redaction: ON — {redaction_count} pattern-matched secret(s) scrubbed from output above")
    else:
        print("redaction: OFF (default) — raw values printed as captured; pass --redact to scrub common secret shapes before sharing/saving this transcript")
    print(f"capture epoch boundaries crossed: {len(boundaries)}")
    print(f"latest wire sequence observed:    {latest_sequence}")
    print("source: this is a retrospective (post-hoc) merge, not a live view.")
    print("==========================================")


if __name__ == '__main__':
    main()
