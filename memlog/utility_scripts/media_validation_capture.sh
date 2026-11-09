#!/usr/bin/env bash
#
# media_validation_capture.sh
#
# Development-only helper for exercising JoesProxy's HLS/DASH Media Info flow
# against real public sample streams. The script sends a small set of requests
# through the running proxy, saves the fetched manifests/segments under memlog/,
# and prints what to inspect in the app afterward.
#
# Usage:
#   ./memlog/utility_scripts/media_validation_capture.sh
#   ./memlog/utility_scripts/media_validation_capture.sh --catalog
#   ./memlog/utility_scripts/media_validation_capture.sh --port 9090
#
# Notes:
#   - The proxy listener must already be running in JoesProxy.
#   - HTTPS interception should be enabled if you want manifest bodies/segments
#     captured rather than tunneled metadata only.
#   - Artifacts stay inside the repo under memlog/media-validation/.
#   - IMPORTANT (confirmed live 2026-08-06, see
#     memlog/Research/MCPAndCLIUserExperienceValidation.md): the apple_bipbop_* samples are
#     bypass-only for JoesProxy's own MCP body-level inspection/editing. `.apple.com` is in
#     TLSInterceptionPolicy.builtInBypassDomains, so even though this script's own curl still
#     fetches the manifest fine (curl isn't going through JoesProxy's TLS interception logic the
#     same way a real app would), the *session JoesProxy captures* for that traffic is a bare
#     CONNECT tunnel with no decrypted body — `response_context`/`response_text_search`/
#     `preview_response_edit`/Map Local all have nothing to work with. Apple's samples remain
#     useful for metadata/timing/Media-Info-classification validation (see "What to inspect"
#     below), but if you need to validate MCP body-level HLS inspection/editing, use the
#     mux_test_streams_x36xhzz sample instead (not on any bypass list).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_XCCONFIG="${ROOT_DIR}/Config/Version.xcconfig"
MARKETING_VERSION_FROM_XCCONFIG="$(grep -m1 '^MARKETING_VERSION' "$VERSION_XCCONFIG" | sed 's/#.*//;s/^[^=]*= *//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
OUTPUT_ROOT="${ROOT_DIR}/memlog/media-validation"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
RUN_DIR="${OUTPUT_ROOT}/${TIMESTAMP}"
PROXY_PORT="9090"
SKIP_CA_VERIFY="${SKIP_CA_VERIFY:-0}"
CATALOG_ONLY=0
TIMEOUT="${TIMEOUT:-20}"
USER_AGENT="${USER_AGENT:-JoesProxy-MediaValidation/${MARKETING_VERSION_FROM_XCCONFIG}}"

usage() {
  cat <<'EOF'
Usage:
  media_validation_capture.sh [--catalog] [--port PORT]

Options:
  --catalog     Print the built-in sample catalog and exit.
  --port PORT   Proxy port (default: 9090).

Environment:
  SKIP_CA_VERIFY=1   Pass -k to curl for HTTPS requests.
  TIMEOUT=20         Per-request timeout in seconds.

Output:
  memlog/media-validation/<timestamp>/
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalog)
      CATALOG_ONLY=1
      shift
      ;;
    --port)
      PROXY_PORT="${2:-}"
      if [[ -z "${PROXY_PORT}" ]]; then
        echo "--port requires a value"
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

catalog() {
  cat <<'EOF'
Built-in development sample catalog

HLS
- apple_bipbop_ts
  https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8
  Why: Apple-hosted TS HLS with master + media playlist + TS segment structure.
  BYPASS-ONLY: .apple.com is in JoesProxy's builtInBypassDomains, so JoesProxy's own captured
  session for this traffic is a bare CONNECT tunnel with no decrypted body. Fine for Media-Info
  classification/timing checks; unusable for MCP body-level inspection/editing (response_context,
  response_text_search, preview_response_edit, Map Local all need a decrypted body to work with).

- apple_bipbop_hevc
  https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8
  Why: Apple-hosted fMP4 HLS with separate playlists and init/media fragments.
  BYPASS-ONLY: same builtInBypassDomains caveat as apple_bipbop_ts above.

- mux_test_streams_x36xhzz
  https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
  Why: Non-Apple public HLS test asset, NOT on any TLS-interception bypass list — use this one
  when you need JoesProxy to actually capture a decrypted body for MCP inspection/editing
  (confirmed live: response_context/response_text_search/preview_response_edit/Map Local all work
  end-to-end against this host). Also a real-world example of a server labeling its master
  playlist Content-Type audio/mpegurl rather than application/vnd.apple.mpegurl.

DASH
- dashif_multires
  https://dash.akamaized.net/dash264/TestCasesUHD/2b/1/MultiRes.mpd
  Why: Stable DASH-IF MPD with representation/template structure.

- dashif_dolby_multirate
  https://dash.akamaized.net/dolby/Test%20Signals/Live/multi_rate/ChID_voices_Multi_200_ddp.mpd
  Why: DASH MPD with a different content profile and SegmentTemplate references.
EOF
}

if [[ "${CATALOG_ONLY}" == "1" ]]; then
  catalog
  exit 0
fi

mkdir -p "${RUN_DIR}"

PROXY="http://127.0.0.1:${PROXY_PORT}"
CURL_COMMON=(
  --silent
  --show-error
  --location
  --max-time "${TIMEOUT}"
  --proxy "${PROXY}"
  --user-agent "${USER_AGENT}"
  --dump-header
)

if [[ "${SKIP_CA_VERIFY}" == "1" ]]; then
  CURL_COMMON+=( -k )
fi

section() {
  echo
  echo "================================================================"
  echo "$1"
  echo "================================================================"
}

ensure_proxy() {
  echo "Checking proxy listener at ${PROXY}..."
  if ! curl --silent --show-error --proxy "${PROXY}" --max-time 5 --output /dev/null http://example.com; then
    echo "Proxy listener did not respond at ${PROXY}."
    echo "Start JoesProxy and enable the listener before running this script."
    exit 1
  fi
}

fetch_to_file() {
  local url="$1"
  local body_path="$2"
  local header_path="$3"
  curl "${CURL_COMMON[@]}" "${header_path}" --output "${body_path}" "${url}"
}

resolve_url() {
  local base="$1"
  local ref="$2"

  if [[ "${ref}" =~ ^https?:// ]]; then
    printf '%s\n' "${ref}"
    return 0
  fi

  local scheme host path_dir
  scheme="${base%%://*}"
  local rest="${base#*://}"
  host="${rest%%/*}"
  local path="/${rest#*/}"
  path_dir="${path%/*}"

  if [[ "${ref}" == //* ]]; then
    printf '%s:%s\n' "${scheme}" "${ref}"
  elif [[ "${ref}" == /* ]]; then
    printf '%s://%s%s\n' "${scheme}" "${host}" "${ref}"
  else
    printf '%s://%s%s/%s\n' "${scheme}" "${host}" "${path_dir}" "${ref}"
  fi
}

extract_first_hls_playlist_uri() {
  local manifest_file="$1"
  awk '
    /^#EXT-X-STREAM-INF:/ { want=1; next }
    want && $0 !~ /^#/ && NF { print; exit }
    /^#EXT-X-I-FRAME-STREAM-INF:/ { next }
  ' "${manifest_file}"
}

extract_first_hls_segment_uri() {
  local manifest_file="$1"
  awk '
    /^#EXT-X-MAP:/ {
      if (match($0, /URI="[^"]+"/)) {
        uri = substr($0, RSTART + 5, RLENGTH - 6)
        print uri
        exit
      }
    }
    $0 !~ /^#/ && NF {
      print
      exit
    }
  ' "${manifest_file}"
}

extract_xml_attribute() {
  local xml_file="$1"
  local attribute_name="$2"
  local value
  value="$(grep -o "${attribute_name}=\"[^\"]*\"" "${xml_file}" | head -n 1 | sed -E "s/^${attribute_name}=\"([^\"]*)\"$/\\1/")"
  printf '%s\n' "${value}"
}

extract_representation_id() {
  local xml_file="$1"
  grep -o 'Representation[^>]*id="[^"]*"' "${xml_file}" | head -n 1 | sed -E 's/.*id="([^"]*)"/\1/'
}

extract_start_number() {
  local xml_file="$1"
  local start_number
  start_number="$(extract_xml_attribute "${xml_file}" "startNumber")"
  if [[ -z "${start_number}" ]]; then
    printf '1\n'
  else
    printf '%s\n' "${start_number}"
  fi
}

substitute_dash_template() {
  local template="$1"
  local representation_id="$2"
  local segment_number="$3"

  local result="${template//\$RepresentationID\$/${representation_id}}"
  result="${result//\$Number\$/${segment_number}}"
  printf '%s\n' "${result}"
}

capture_hls_sample() {
  local name="$1"
  local master_url="$2"
  local sample_dir="${RUN_DIR}/${name}"
  mkdir -p "${sample_dir}"

  local master_body="${sample_dir}/master.m3u8"
  local master_headers="${sample_dir}/master.headers.txt"

  section "HLS · ${name}"
  echo "Master: ${master_url}"
  fetch_to_file "${master_url}" "${master_body}" "${master_headers}"

  local child_ref child_url child_body child_headers segment_ref segment_url segment_body segment_headers
  child_ref="$(extract_first_hls_playlist_uri "${master_body}")"
  if [[ -z "${child_ref}" ]]; then
    echo "Could not find child playlist URI in ${master_url}"
    return 1
  fi
  child_url="$(resolve_url "${master_url}" "${child_ref}")"
  child_body="${sample_dir}/media-playlist.m3u8"
  child_headers="${sample_dir}/media-playlist.headers.txt"
  echo "Media playlist: ${child_url}"
  fetch_to_file "${child_url}" "${child_body}" "${child_headers}"

  segment_ref="$(extract_first_hls_segment_uri "${child_body}")"
  if [[ -z "${segment_ref}" ]]; then
    echo "Could not find init/segment URI in ${child_url}"
    return 1
  fi
  segment_url="$(resolve_url "${child_url}" "${segment_ref}")"
  local segment_name
  segment_name="$(basename "${segment_url%%\?*}")"
  segment_body="${sample_dir}/${segment_name}"
  segment_headers="${sample_dir}/${segment_name}.headers.txt"
  echo "Segment/init: ${segment_url}"
  fetch_to_file "${segment_url}" "${segment_body}" "${segment_headers}"
}

capture_dash_sample() {
  local name="$1"
  local mpd_url="$2"
  local sample_dir="${RUN_DIR}/${name}"
  mkdir -p "${sample_dir}"

  local mpd_body="${sample_dir}/manifest.mpd"
  local mpd_headers="${sample_dir}/manifest.headers.txt"

  section "DASH · ${name}"
  echo "MPD: ${mpd_url}"
  fetch_to_file "${mpd_url}" "${mpd_body}" "${mpd_headers}"

  local representation_id start_number init_template media_template
  representation_id="$(extract_representation_id "${mpd_body}")"
  start_number="$(extract_start_number "${mpd_body}")"
  init_template="$(extract_xml_attribute "${mpd_body}" "initialization")"
  media_template="$(extract_xml_attribute "${mpd_body}" "media")"

  if [[ -z "${representation_id}" || -z "${init_template}" || -z "${media_template}" ]]; then
    echo "Could not derive init/media template data from ${mpd_url}"
    return 1
  fi

  local init_ref media_ref init_url media_url init_name media_name
  init_ref="$(substitute_dash_template "${init_template}" "${representation_id}" "${start_number}")"
  media_ref="$(substitute_dash_template "${media_template}" "${representation_id}" "${start_number}")"
  init_url="$(resolve_url "${mpd_url}" "${init_ref}")"
  media_url="$(resolve_url "${mpd_url}" "${media_ref}")"

  init_name="$(basename "${init_url%%\?*}")"
  media_name="$(basename "${media_url%%\?*}")"

  echo "Init segment: ${init_url}"
  fetch_to_file "${init_url}" "${sample_dir}/${init_name}" "${sample_dir}/${init_name}.headers.txt"

  echo "Media segment: ${media_url}"
  fetch_to_file "${media_url}" "${sample_dir}/${media_name}" "${sample_dir}/${media_name}.headers.txt"
}

print_next_steps() {
  cat <<EOF

Saved validation artifacts to:
  ${RUN_DIR}

What to inspect in JoesProxy:
- Filter by host:
  - devstreaming-cdn.apple.com (bypass-only — CONNECT tunnel, no decrypted body; see BYPASS-ONLY
    note in --catalog)
  - test-streams.mux.dev (full body capture — use this one for MCP body-level inspection/editing)
  - dash.akamaized.net
- Confirm Media Info classifies:
  - HLS manifests as Manifest
  - HLS init/segment responses as Init Segment / Media Segment
  - DASH MPDs as Manifest
  - DASH init/media responses as Init Segment / Media Segment
- Open Media Info on the binary responses and verify:
  - HLS/DASH manifest correlation is present
  - matched manifest path and reference URI are shown
  - TS/fMP4 structure appears on captured binary responses
  - DASH adaptation/representation/template rows are populated
- For MCP body-level HLS validation specifically (response_context/response_text_search/
  preview_response_edit/Map Local), drive the mux_test_streams_x36xhzz session through those tools
  directly — do not use the apple_bipbop_* sessions for this, they have no captured body.

Local artifact checks:
- ${RUN_DIR}/apple_bipbop_ts/
- ${RUN_DIR}/apple_bipbop_hevc/
- ${RUN_DIR}/mux_test_streams_x36xhzz/
- ${RUN_DIR}/dashif_multires/
- ${RUN_DIR}/dashif_dolby_multirate/
EOF
}

catalog
ensure_proxy

capture_hls_sample \
  "apple_bipbop_ts" \
  "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"

capture_hls_sample \
  "apple_bipbop_hevc" \
  "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8"

capture_hls_sample \
  "mux_test_streams_x36xhzz" \
  "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"

capture_dash_sample \
  "dashif_multires" \
  "https://dash.akamaized.net/dash264/TestCasesUHD/2b/1/MultiRes.mpd"

capture_dash_sample \
  "dashif_dolby_multirate" \
  "https://dash.akamaized.net/dolby/Test%20Signals/Live/multi_rate/ChID_voices_Multi_200_ddp.mpd"

print_next_steps
