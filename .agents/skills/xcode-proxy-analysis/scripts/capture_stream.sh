#!/bin/zsh
# Passive-only console/log capture, correlated with a JoesProxy capture-sequence header.
#
# Deliberately supports ONLY modes that are root-free and never disrupt a running app:
#   sim            <udid|booted> <label> [process-filter]  -- Simulator, live NDJSON stream
#   device-syslog  <name>        <label> [process-filter]  -- device, live filtered relay
#   device-archive <name>        <label> [age]              -- device, retrospective backfill
#
# `process-filter` (sim/device-syslog) narrows to one process by name — e.g. your app's binary
# name. Without it, `sim` mode captures the ENTIRE simulator's system-wide log stream, which is
# large fast (measured: ~30MB in under 10 seconds on an idle simulator) and mostly irrelevant OS
# noise. Pass a filter whenever you know the target process name.
#
# Deliberately NOT included (available only as manual, human-run steps if you explicitly choose
# them — never invoked by this script or by an agent by default):
#   - a `sudo log collect` mode (requires root)
#   - a `devicectl process launch --console` mode (owns the app launch, forwards signals to it,
#     and can kill the app if this process is killed — see
#     memlog/mcp-usage-feedback/tools/capture_logs.sh for that historical, discouraged mechanism)
#
# No defaults are baked in: every device/label argument must be passed explicitly.
#
# Usage:
#   capture_stream.sh sim <udid|booted> <label> [process-filter]
#   capture_stream.sh device-syslog <device-name> <label> [process-filter]
#   capture_stream.sh device-archive <device-name> <label> [age]
#
# Stop a streaming capture with Ctrl-C (or `kill <pid>`); only this script's own capture
# subprocess is ever signaled — never a broad pkill, never another process's session.
set -u

SCRIPT_DIR="${0:A:h}"
OUT_DIR="${CONSOLE_LOG_DIR:-$SCRIPT_DIR/../../../../ConsoleLogCaptures}"
mkdir -p "$OUT_DIR"

MODE="${1:-}"
[ -z "$MODE" ] && { sed -n '2,20p' "$0"; exit 1 }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

IDEVICESYSLOG="${IDEVICESYSLOG:-/opt/homebrew/bin/idevicesyslog}"
IDEVICE_ID="${IDEVICE_ID:-/opt/homebrew/bin/idevice_id}"
IDEVICEINFO="${IDEVICEINFO:-/opt/homebrew/bin/ideviceinfo}"

JOESPROXYCTL="${JOESPROXYCTL:-joesproxyctl}"
JOESPROXY_ENDPOINT="${JOESPROXY_ENDPOINT:-http://127.0.0.1:9091/mcp}"

# Resolve a device *name* to a UDID and work out whether it is USB- or network-attached.
# Network-attached devices require -n; omitting it makes the tools silently see nothing.
# Sets: DEV_UDID, DEV_LINK ("USB"|"Network"), DEV_ARGS (array of args for idevice* tools).
resolve_device() {
  local want="$1" udid name
  DEV_UDID=""; DEV_LINK=""; DEV_ARGS=()
  for udid in $("$IDEVICE_ID" -l 2>/dev/null); do
    name=$("$IDEVICEINFO" -u "$udid" -k DeviceName 2>/dev/null)
    if [[ "$name" == "$want" || "$udid" == "$want" ]]; then
      DEV_UDID="$udid"; DEV_LINK="USB"; DEV_ARGS=(-u "$udid"); return 0
    fi
  done
  for udid in $("$IDEVICE_ID" -n 2>/dev/null); do
    name=$("$IDEVICEINFO" -n -u "$udid" -k DeviceName 2>/dev/null)
    if [[ "$name" == "$want" || "$udid" == "$want" ]]; then
      DEV_UDID="$udid"; DEV_LINK="Network"; DEV_ARGS=(-n -u "$udid"); return 0
    fi
  done
  print -u2 -- "resolve_device: '$want' not found. Visible devices:"
  "$IDEVICE_ID" 2>/dev/null | sed 's/^/  /' >&2
  return 1
}

# Reports (does not kill) an existing idevicesyslog session already targeting this device, so a
# second capture doesn't silently compete with — or get blamed for interference from — one
# already in progress.
warn_if_relay_busy() {
  local udid="$1"
  local existing
  existing=$(pgrep -f "idevicesyslog.*$udid" 2>/dev/null | grep -v "^$$\$" || true)
  if [ -n "$existing" ]; then
    print -u2 -- "NOTE: idevicesyslog already appears to be running for this device (pid(s): $existing)."
    print -u2 -- "      Not stopping it — a second relay may simply see the same stream twice,"
    print -u2 -- "      or the device may reject a second connection. If this capture looks empty"
    print -u2 -- "      or duplicated, that pre-existing session is the likely reason."
  fi
}

# --- correlation anchor: ask JoesProxy where the capture is right now -------------
# Uses joesproxyctl (JoesProxyCLI) + jq — no inline python3 -c.
proxy_seq() {
  local json
  json=$("$JOESPROXYCTL" capture digest --endpoint "$JOESPROXY_ENDPOINT" --json 2>/dev/null)
  if [ -z "$json" ]; then
    print -r -- "unavailable unavailable"
    return
  fi
  print -r -- "$json" | jq -r '
    if .success then "\(.result.payload.latestSequence) \(.result.payload.captureEpoch.rawValue)"
    else "unavailable unavailable" end
  ' 2>/dev/null || print -r -- "unavailable unavailable"
}

write_header() {
  local f="$1" mode="$2" target="$3" seq="$4" epoch="$5"
  {
    print -r -- "# ===== CONSOLE LOG CAPTURE ====="
    print -r -- "# startedAtUTC:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    print -r -- "# mode:                $mode"
    print -r -- "# target:              $target"
    print -r -- "# joesproxySeqAtStart: $seq"
    print -r -- "# joesproxyEpochAtStart: $epoch"
    print -r -- "# hostTZ:              $(date +%Z) (offset $(date +%z))"
    print -r -- "# xcodeVersion:        $(xcodebuild -version 2>/dev/null | head -1)"
    print -r -- "# gitBranch:           $(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    print -r -- "# gitHead:             $(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null)"
    print -r -- "# correlate with:      joesproxyctl sessions list --since-sequence $seq --limit 100 --projection summary --json"
    print -r -- "# live-correlate with: correlate_live.py <this file> --since-sequence $seq"
    print -r -- "# batch-correlate with: correlate_batch.py <this file> --since-sequence $seq"
    print -r -- "# =============================="
  } >> "$f"
}

write_footer() {
  local f="$1"
  local seq epoch
  read -r seq epoch <<< "$(proxy_seq)"
  {
    print -r -- "# ===== CAPTURE END ====="
    print -r -- "# endedAtUTC:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    print -r -- "# joesproxySeqAtEnd: $seq"
    print -r -- "# joesproxyEpochAtEnd: $epoch"
    print -r -- "# ======================="
  } >> "$f"
}

# Only this script's own capture child is ever signaled — CAPTURE_PID is set right after each
# background capture is spawned, and the trap below targets exactly that PID, nothing broader.
CAPTURE_PID=""
on_interrupt() {
  local out="$1"
  [ -n "$CAPTURE_PID" ] && kill "$CAPTURE_PID" 2>/dev/null
  write_footer "$out"
  print -r -- "saved: $out"
  exit 0
}

case "$MODE" in

sim)
  UDID="${2:?usage: capture_stream.sh sim <udid|booted> <label> [process-filter]}"
  LABEL="${3:?usage: capture_stream.sh sim <udid|booted> <label> [process-filter]}"
  PROC="${4:-}"
  OUT="$OUT_DIR/${STAMP}-sim-${LABEL}.log"
  read -r SEQ EPOCH <<< "$(proxy_seq)"
  write_header "$OUT" "sim" "$UDID${PROC:+ proc=$PROC}" "$SEQ" "$EPOCH"
  print -r -- "Capturing simulator log (NDJSON) -> $OUT   (proxy seq $SEQ, epoch $EPOCH)  Ctrl-C to stop."
  [ -z "$PROC" ] && print -u2 -- "NOTE: no process filter given — this captures the ENTIRE simulator's log stream (large fast). Pass a process name to narrow it."
  trap 'on_interrupt "$OUT"' INT TERM
  # --style ndjson gives one structured JSON object per line with an authoritative `timestamp`
  # field — scripts/normalize.py parses this directly, no timestamp-passthrough heuristics needed.
  typeset -a predicate_args
  if [ -n "$PROC" ]; then predicate_args=(--predicate "process == \"$PROC\""); else predicate_args=(); fi
  xcrun simctl spawn "$UDID" log stream --level debug --style ndjson "${predicate_args[@]}" >> "$OUT" 2>&1 &
  CAPTURE_PID=$!
  wait "$CAPTURE_PID"
  write_footer "$OUT"
  ;;

device-syslog)
  # Live stream. No root, does NOT own the app launch, safe alongside an Xcode debug session.
  NAME="${2:?usage: capture_stream.sh device-syslog <device-name> <label> [process-filter]}"
  LABEL="${3:?usage: capture_stream.sh device-syslog <device-name> <label> [process-filter]}"
  PROC="${4:-}"
  [ -x "$IDEVICESYSLOG" ] || {
    print -r -- "idevicesyslog not found at $IDEVICESYSLOG (brew install libimobiledevice)"; exit 1
  }
  resolve_device "$NAME" || exit 1
  warn_if_relay_busy "$DEV_UDID"
  OUT="$OUT_DIR/${STAMP}-devicesyslog-${LABEL}.log"
  read -r SEQ EPOCH <<< "$(proxy_seq)"
  write_header "$OUT" "device-syslog" "$NAME ($DEV_UDID, $DEV_LINK)${PROC:+ proc=$PROC}" "$SEQ" "$EPOCH"
  print -r -- "Streaming $NAME [$DEV_LINK] -> $OUT   (proxy seq $SEQ, epoch $EPOCH)  Ctrl-C to stop."
  trap 'on_interrupt "$OUT"' INT TERM
  # -p (include one process) and -q/-e (exclude processes) are MUTUALLY EXCLUSIVE.
  typeset -a filt
  if [ -n "$PROC" ]; then filt=(-p "$PROC"); else filt=(-q); fi
  "$IDEVICESYSLOG" "${DEV_ARGS[@]}" "${filt[@]}" >> "$OUT" 2>&1 &
  CAPTURE_PID=$!
  wait "$CAPTURE_PID"
  write_footer "$OUT"
  ;;

device-archive)
  # Full unified log (.logarchive) pulled from the device WITHOUT root. Retrospective: captures a
  # window that already happened, so there is no live process to interrupt.
  NAME="${2:?usage: capture_stream.sh device-archive <device-name> <label> [age]}"
  LABEL="${3:?usage: capture_stream.sh device-archive <device-name> <label> [age]}"
  AGE="${4:-15m}"
  [ -x "$IDEVICESYSLOG" ] || {
    print -r -- "idevicesyslog not found at $IDEVICESYSLOG (brew install libimobiledevice)"; exit 1
  }
  resolve_device "$NAME" || exit 1
  OUT="$OUT_DIR/${STAMP}-devicearchive-${LABEL}.log"
  TAR="$OUT_DIR/${STAMP}-${LABEL}.logarchive.tar"
  ARCHDIR="$OUT_DIR/${STAMP}-${LABEL}.logarchive"
  read -r SEQ EPOCH <<< "$(proxy_seq)"
  write_header "$OUT" "device-archive" "$NAME ($DEV_UDID, $DEV_LINK) age=$AGE" "$SEQ" "$EPOCH"
  print -r -- "Requesting logarchive (age-limit $AGE) from $NAME [$DEV_LINK]..."
  "$IDEVICESYSLOG" "${DEV_ARGS[@]}" archive "$TAR" --age-limit "$AGE" || {
    print -r -- "archive request failed"; exit 1
  }
  mkdir -p "$ARCHDIR" && tar -xf "$TAR" -C "$ARCHDIR" && rm -f "$TAR"
  INNER="$(find "$ARCHDIR" -maxdepth 2 -name '*.logarchive' -o -maxdepth 2 -name 'Extra' | head -1)"
  /usr/bin/log show "${INNER:-$ARCHDIR}" --style ndjson --info --debug >> "$OUT" 2>/dev/null \
    || print -r -- "# (log show could not read the archive directly; bundle kept at $ARCHDIR)" >> "$OUT"
  write_footer "$OUT"
  print -r -- "saved: $OUT   (archive bundle: $ARCHDIR)"
  ;;

*)
  print -r -- "unknown or unsupported mode: $MODE"
  print -r -- "(device-collect and device-console are intentionally not offered by this script —"
  print -r -- " see the header comment and .agents/skills/xcode-proxy-analysis/SKILL.md.)"
  sed -n '2,20p' "$0"
  exit 1
  ;;
esac
