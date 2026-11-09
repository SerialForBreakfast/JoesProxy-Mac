"""Canonical event-record normalization shared by correlate_batch.py and correlate_live.py.

Every raw line/record from every source (Simulator NDJSON log stream, idevicesyslog syslog-style
relay, or a JoesProxy wire session from `joesproxyctl sessions list`) is converted into one `Event`
record before merging. An unparseable line is never dropped — it is preserved with
`parseStatus="degraded"` and ordered by host-receipt time instead of a (possibly wrong) guessed
source time. This is deliberate: a clean-looking transcript with silently-dropped lines is worse
than one that visibly admits what it could not parse.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone


@dataclass
class Event:
    sourceType: str          # "app" | "wire"
    tsUTC: datetime | None   # authoritative timestamp, in UTC, if parseable
    tsOriginal: str          # the source's own raw timestamp text, unmodified
    tsHostReceipt: datetime  # when this process observed the line/record (always UTC, always set)
    parseStatus: str         # "ok" | "degraded"
    raw: str                 # the original line or a compact rendering of the source record

    def orderingKey(self) -> datetime:
        """Degraded events sort by host-receipt time since their own timestamp is untrustworthy."""
        return self.tsUTC if self.tsUTC is not None else self.tsHostReceipt


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


# --- Simulator: `xcrun simctl spawn <UDID> log stream --style ndjson` ------------------------
# Each line is a JSON object; `timestamp` looks like "2026-08-01 20:29:28.123456-0700" (local time,
# microsecond precision, explicit numeric offset — NOT ISO-8601, no 'T', no 'Z').
_SIM_TS = re.compile(
    r'^(?P<dt>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.(?P<frac>\d+)(?P<off>[+-]\d{4})$'
)


def parse_simulator_ndjson_line(line: str) -> Event:
    host_receipt = now_utc()
    line = line.rstrip('\n')
    try:
        record = json.loads(line)
    except ValueError:
        return Event('app', None, '', host_receipt, 'degraded', line)

    ts_raw = str(record.get('timestamp', ''))
    ts_utc = _parse_simulator_timestamp(ts_raw)
    message = record.get('eventMessage', '')
    subsystem = record.get('subsystem', '')
    category = record.get('category', '')
    rendered = f"[{subsystem}/{category}] {message}" if subsystem or category else message
    status = 'ok' if ts_utc is not None else 'degraded'
    return Event('app', ts_utc, ts_raw, host_receipt, status, rendered or line)


def _parse_simulator_timestamp(ts_raw: str) -> datetime | None:
    m = _SIM_TS.match(ts_raw)
    if not m:
        return None
    frac = m.group('frac')[:6].ljust(6, '0')  # datetime.strptime %f wants exactly 6 digits
    off = m.group('off')
    try:
        local = datetime.strptime(f"{m.group('dt')}.{frac}{off}", '%Y-%m-%d %H:%M:%S.%f%z')
    except ValueError:
        return None
    return local.astimezone(timezone.utc)


# --- idevicesyslog: syslog-style relay/archive lines ------------------------------------------
# Typical shape: "Aug  1 20:29:28 <device-name> <process>[pid] <subsystem>: message"
# No year, no fractional seconds, no explicit offset — device-local time, assumed to share the
# host's timezone (both machines are expected to be on the same local clock during a capture
# session; this is a best-effort reconstruction, not a guaranteed-correct one).
_SYSLOG_TS = re.compile(
    r'^(?P<mon>[A-Z][a-z]{2})\s+(?P<day>\d{1,2})\s+(?P<time>\d{2}:\d{2}:\d{2})\s+(?P<rest>.*)$'
)
_MONTHS = {
    m: i + 1
    for i, m in enumerate(
        ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
    )
}


def parse_idevicesyslog_line(line: str, reference_year: int | None = None) -> Event:
    host_receipt = now_utc()
    line = line.rstrip('\n')
    m = _SYSLOG_TS.match(line)
    if not m:
        return Event('app', None, '', host_receipt, 'degraded', line)

    month = _MONTHS.get(m.group('mon'))
    if month is None:
        return Event('app', None, m.group('mon'), host_receipt, 'degraded', line)

    year = reference_year or host_receipt.year
    ts_raw = f"{m.group('mon')} {m.group('day')} {m.group('time')}"
    try:
        naive_local = datetime.strptime(
            f"{year}-{month:02d}-{int(m.group('day')):02d} {m.group('time')}",
            '%Y-%m-%d %H:%M:%S',
        )
    except ValueError:
        return Event('app', None, ts_raw, host_receipt, 'degraded', line)

    local = naive_local.astimezone()  # attach the host's local timezone
    ts_utc = local.astimezone(timezone.utc)
    # Guard against an obviously-wrong reconstruction (e.g. capture spanning a year boundary) —
    # if the reconstructed timestamp is more than a day in the future relative to when we received
    # it, the year guess was probably wrong; degrade rather than assert a bad absolute time.
    if ts_utc > host_receipt.replace(microsecond=0) + timedelta(days=1):
        return Event('app', None, ts_raw, host_receipt, 'degraded', line)
    return Event('app', ts_utc, ts_raw, host_receipt, 'ok', m.group('rest'))


# --- JoesProxy wire sessions: `joesproxyctl sessions list` payload items ----------------------

def wire_event_from_session(session: dict) -> Event:
    host_receipt = now_utc()
    started_at = session.get('startedAt')
    ts_utc = None
    if started_at:
        try:
            ts_utc = datetime.fromisoformat(str(started_at).replace('Z', '+00:00'))
        except ValueError:
            ts_utc = None
    duration = session.get('durationSeconds')
    dur_text = f"{duration:.3f}s" if isinstance(duration, (int, float)) else "   -   "
    category = session.get('mediaCategory', 'none')
    method = session.get('method', '')
    host = session.get('sanitizedHost', '')
    path = str(session.get('sanitizedPath', ''))[:70]
    seq = session.get('captureSequence')
    rendered = f"seq{seq:<6} {dur_text:>8} [{category}] {method} {host}{path}"
    status = 'ok' if ts_utc is not None else 'degraded'
    return Event('wire', ts_utc, str(started_at), host_receipt, status, rendered)
