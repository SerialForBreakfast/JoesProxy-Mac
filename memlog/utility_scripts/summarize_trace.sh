#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 path/to/trace.trace"
  exit 64
fi

TRACE_PATH="$1"

if [[ ! -e "$TRACE_PATH" ]]; then
  echo "Trace not found: $TRACE_PATH" >&2
  exit 66
fi

TRACE_DIR="$(dirname "$TRACE_PATH")"
TRACE_NAME="$(basename "$TRACE_PATH" .trace)"
TOC_PATH="$TRACE_DIR/$TRACE_NAME.toc.xml"
PROFILE_PATH="$TRACE_DIR/$TRACE_NAME-time-profile.xml"
SAMPLE_PATH="$TRACE_DIR/$TRACE_NAME-time-sample.xml"

echo "==> exporting trace data for $TRACE_NAME"
xcrun xctrace export --input "$TRACE_PATH" --toc --output "$TOC_PATH" >/dev/null
xcrun xctrace export --input "$TRACE_PATH" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output "$PROFILE_PATH" >/dev/null
xcrun xctrace export --input "$TRACE_PATH" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-sample"]' --output "$SAMPLE_PATH" >/dev/null

TOTAL_PROFILE_ROWS="$(rg -c '<sample-time ' "$PROFILE_PATH")"
MAIN_THREAD_ID="$(rg -o '<thread id="([0-9]+)" fmt="Main Thread' -r '$1' "$PROFILE_PATH" | head -n 1)"

if [[ -z "${MAIN_THREAD_ID:-}" ]]; then
  echo "Could not determine main thread id from $PROFILE_PATH" >&2
  exit 65
fi

MAIN_THREAD_ROWS="$(rg -c "<thread (id|ref)=\"$MAIN_THREAD_ID\"" "$PROFILE_PATH")"
TOTAL_SAMPLE_ROWS="$(rg -c '<sample-time ' "$SAMPLE_PATH")"

COPY_COUNT="$(rg -c 'initializeWithCopy for SessionRecord' "$PROFILE_PATH")"
DESTROY_COUNT="$(rg -c 'destroy for SessionRecord' "$PROFILE_PATH")"
STORE_APPEND_COUNT="$(rg -c 'InMemorySessionStore.append\\(_:\\)' "$PROFILE_PATH")"
SUBJECT_SEND_COUNT="$(rg -c 'CurrentValueSubject.send\\(_:\\)' "$PROFILE_PATH")"
UI_CHROME_COUNT="$(rg -c 'PlatformItemListGenerator|AttributeGraph|AppKitMenuCore' "$PROFILE_PATH")"

echo
echo "Trace: $TRACE_PATH"
echo "TOC: $TOC_PATH"
echo "Time profile rows: $TOTAL_PROFILE_ROWS"
echo "Time sample rows: $TOTAL_SAMPLE_ROWS"
echo "Main thread id: $MAIN_THREAD_ID"
echo "Main thread profile rows: $MAIN_THREAD_ROWS"
echo "Main thread share: $(awk "BEGIN { printf \"%.2f%%\", ($MAIN_THREAD_ROWS / $TOTAL_PROFILE_ROWS) * 100 }")"
echo
echo "Hotspot counts:"
echo "  SessionRecord initializeWithCopy: $COPY_COUNT"
echo "  SessionRecord destroy: $DESTROY_COUNT"
echo "  InMemorySessionStore.append(_:): $STORE_APPEND_COUNT"
echo "  CurrentValueSubject.send(_:): $SUBJECT_SEND_COUNT"
echo "  UI chrome signatures (PlatformItemListGenerator / AttributeGraph / AppKitMenuCore): $UI_CHROME_COUNT"
