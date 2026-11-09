#!/usr/bin/env bash
# Fetch the live media playlist for a fixture audio rendition through JoesProxy (TLS verified).
#
# Usage:
#   fetch_live_audio_playlist.sh --host <fixture-host> --audio-target ad \
#     --proxy-port 9090 --cacert <pem> --out <file>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=memlog/utility_scripts/joeplayer_suite/lib.sh
. "$SCRIPT_DIR/lib.sh"

HOST=""
AUDIO_TARGET="ad"
PROXY_PORT="9090"
CACERT=""
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:?}"; shift 2 ;;
    --audio-target) AUDIO_TARGET="${2:?}"; shift 2 ;;
    --proxy-port) PROXY_PORT="${2:?}"; shift 2 ;;
    --cacert) CACERT="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help)
      echo "usage: $0 --host <host> --audio-target <id> --proxy-port <n> --cacert <pem> --out <file>"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$HOST" && -n "$CACERT" && -n "$OUT" ]] || { echo "missing required arguments" >&2; exit 2; }
[[ -s "$CACERT" ]] || die "CA PEM missing or empty: $CACERT"

url="https://${HOST}/audio-${AUDIO_TARGET}/stream.m3u8"
# Mirror probe_proxy_routing's -x pattern; verify TLS with the JoesProxy root CA (no -k).
if ! curl -fsS --http1.1 \
  -x "http://127.0.0.1:${PROXY_PORT}" \
  --cacert "$CACERT" \
  --max-time 10 \
  "$url" -o "$OUT"; then
  die "Failed to fetch live playlist via proxy: $url"
fi

[[ -s "$OUT" ]] || die "Live playlist empty: $OUT"
if ! grep -q '^#EXTM3U' "$OUT"; then
  die "Live playlist does not look like HLS: $OUT"
fi

media_seq="$(grep -m1 '^#EXT-X-MEDIA-SEQUENCE:' "$OUT" | cut -d: -f2 || true)"
seg_count="$(grep -cE '^[^#].+\.ts$' "$OUT" || true)"
log "Fetched live playlist mediaSequence=${media_seq:-?} segments=$seg_count url=$url"
