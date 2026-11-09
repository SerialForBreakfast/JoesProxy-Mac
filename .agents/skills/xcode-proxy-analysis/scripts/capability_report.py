#!/usr/bin/env python3
"""Honest preflight report: what this run can and cannot observe.

Usage:
  capability_report.py [--endpoint URL]

Run this before starting a capture. "Works with any Xcode project, no SDK required" means no
app-side integration is needed to get *something* — it does not mean every project's console
output will be complete. This script states the known ceiling plainly so an agent doesn't
overclaim completeness from a clean-looking transcript later.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys


def check_tool(name: str) -> tuple[bool, str]:
    path = shutil.which(name)
    return (path is not None, path or "not found on PATH")


def check_xcrun_tool(name: str) -> tuple[bool, str]:
    """`simctl`/`devicectl` are invoked as `xcrun <name>`, not standalone PATH binaries."""
    if shutil.which('xcrun') is None:
        return False, "xcrun not found"
    try:
        result = subprocess.run(['xcrun', '-f', name], capture_output=True, text=True, timeout=10)
    except Exception as e:
        return False, f"xcrun -f {name} failed: {e}"
    if result.returncode == 0 and result.stdout.strip():
        return True, result.stdout.strip()
    return False, f"xcrun could not locate {name}"


def check_joesproxyctl(endpoint: str) -> tuple[bool, str]:
    if shutil.which('joesproxyctl') is None:
        return False, "joesproxyctl not found on PATH"
    try:
        out = subprocess.run(
            ['joesproxyctl', 'status', '--endpoint', endpoint, '--json'],
            capture_output=True, text=True, timeout=15,
        ).stdout
        data = json.loads(out)
    except Exception as e:
        return False, f"joesproxyctl status failed to run: {e}"
    if not data.get('success', False):
        msg = data.get('errorMessage', 'unknown error')
        if 'credential' in msg.lower() or 'auth' in msg.lower():
            return False, f"not authenticated — run `joesproxyctl auth login` first ({msg})"
        return False, f"joesproxyctl status returned an error: {msg}"
    payload = data['result']['payload']
    running = payload.get('isRunning', False)
    tool_count = payload.get('toolCount', 0)
    epoch = (payload.get('captureEpoch') or {}).get('rawValue', 'unknown')
    return running, f"JoesProxy running={running}, {tool_count} MCP tools, capture epoch={epoch}"


def check_simulators() -> tuple[bool, str]:
    try:
        out = subprocess.run(
            ['xcrun', 'simctl', 'list', 'devices', 'booted'],
            capture_output=True, text=True, timeout=15,
        ).stdout
    except Exception as e:
        return False, f"simctl failed to run: {e}"
    booted = [ln.strip() for ln in out.splitlines() if '(Booted)' in ln]
    if booted:
        return True, f"{len(booted)} booted simulator(s): " + '; '.join(booted)
    return False, "no booted simulator"


def check_devices() -> tuple[bool, str]:
    if shutil.which('idevice_id') is None:
        return False, "idevice_id not found (brew install libimobiledevice) — device modes unavailable"
    try:
        usb = subprocess.run(['idevice_id', '-l'], capture_output=True, text=True, timeout=10).stdout.split()
        net = subprocess.run(['idevice_id', '-n'], capture_output=True, text=True, timeout=10).stdout.split()
    except Exception as e:
        return False, f"idevice_id failed to run: {e}"
    if usb or net:
        return True, f"{len(usb)} USB, {len(net)} network-paired device(s)"
    return False, "no paired physical device found"


LIMITS = """
Known completeness ceiling (true regardless of which project you point this at):
  - Physical-device idevicesyslog only carries Notice-and-above SYSTEM messages by default —
    it does NOT capture app stdout, or Debug/Info-level app logs, unless narrowly filtered to
    exactly your process, and even then coverage is not guaranteed complete.
  - `print`/`debugPrint` output never enters the unified logging system (os_log) at all, on
    either Simulator or device — if the target app only uses print(), none of these capture
    modes will see it. Structured os_log/Logger calls are what these modes can actually observe.
  - Values the OS marks `<private>` stay redacted in every capture mode here; only an attached
    Xcode debugger session can lift that redaction, and this skill deliberately never attaches
    one (that would be an active/disruptive action, out of scope for passive capture).
  - `device-archive` is retrospective (a window that already happened); `sim`/`device-syslog`
    are live-only, from the moment they start.
  - "No SDK required" means this works without any app-side integration — it does not mean
    every project's console output will be complete or sufficient on its own. If a diagnosis
    needs application-level detail these modes can't see, that is a real gap, not a bug in the
    capture — the honest next step is adding a structured os_log call at that specific point,
    not assuming this tooling missed something it could have caught.
""".strip()


def main() -> None:
    endpoint = 'http://127.0.0.1:9091/mcp'
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == '--endpoint':
            endpoint = args[i + 1]; i += 2
        else:
            i += 1

    print("===== CAPABILITY REPORT =====")
    for label, (ok, detail) in [
        ("simctl", check_xcrun_tool('simctl')),
        ("idevicesyslog", check_tool('idevicesyslog')),
        ("devicectl", check_xcrun_tool('devicectl')),
        ("joesproxyctl + JoesProxy", check_joesproxyctl(endpoint)),
        ("booted simulator", check_simulators()),
        ("paired physical device", check_devices()),
    ]:
        mark = "OK" if ok else "--"
        print(f"[{mark}] {label}: {detail}")
    print("")
    print(LIMITS)
    print("==============================")


if __name__ == '__main__':
    main()
