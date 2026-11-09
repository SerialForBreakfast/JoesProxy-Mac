#!/usr/bin/env bash
#
# proxy_smoke_test.sh
#
# Sends a variety of HTTP and HTTPS requests through JoesProxy at 1-second intervals
# to exercise session capture, JSON inspection, media detection, HTTPS interception,
# and the Explorer / Map Local surfaces — without needing a physical device.
#
# Usage:
#   chmod +x memlog/proxy_smoke_test.sh
#   ./memlog/proxy_smoke_test.sh [PORT]
#
# PORT defaults to 9090.
#
# Prerequisites:
#   - JoesProxy is running and the proxy listener is started.
#   - For HTTPS tests: the JoesProxy Root CA is installed and trusted on this Mac,
#     OR run with --no-ca-verify (pass -k to curl) and set SKIP_CA_VERIFY=1.
#     Without trust, HTTPS sessions will appear as tunneled, not intercepted.
#
# Environment variables:
#   PROXY_PORT       Override the proxy port (default: 9090)
#   DELAY            Seconds between requests (default: 1)
#   SKIP_CA_VERIFY   Set to 1 to pass -k to curl (disables CA verification)
#   TIMEOUT          Per-request timeout in seconds (default: 10)

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

PROXY_PORT="${PROXY_PORT:-${1:-9090}}"
DELAY="${DELAY:-1}"
TIMEOUT="${TIMEOUT:-10}"
SKIP_CA_VERIFY="${SKIP_CA_VERIFY:-0}"
PROXY="http://127.0.0.1:${PROXY_PORT}"

# ── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Counters ──────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0
TOTAL=0

# ── Helpers ───────────────────────────────────────────────────────────────────

section() {
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  $1${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
}

# send LABEL URL [extra curl args...]
#
# Sends ONE request through the proxy, prints the HTTP status and timing,
# and records pass/fail. A single curl call captures both the status code
# and timing so that only one session appears in JoesProxy per invocation.
send() {
    local label="$1"
    shift
    local url="$1"
    shift
    TOTAL=$((TOTAL + 1))

    local ca_flag=""
    if [[ "${SKIP_CA_VERIFY}" == "1" ]]; then
        ca_flag="-k"
    fi

    echo -e "${DIM}[$TOTAL]${RESET} ${BOLD}${label}${RESET}"
    echo -e "    ${DIM}${url}${RESET}"

    # Single curl call: write status code and total time on the last line of
    # stdout, separated by a space. The response body is discarded.
    local write_out
    write_out=$(
        curl --silent \
             --proxy "${PROXY}" \
             --max-time "${TIMEOUT}" \
             --write-out "%{http_code} %{time_total}" \
             --output /dev/null \
             ${ca_flag} \
             "$@" \
             "${url}" 2>&1
    ) || true

    local http_code timing
    http_code=$(echo "${write_out}" | awk '{print $1}')
    timing=$(echo "${write_out}" | awk '{print $2}')

    if [[ "${http_code}" =~ ^[0-9]+$ ]] && [[ "${http_code}" -gt 0 ]]; then
        if [[ "${http_code}" -lt 400 ]]; then
            echo -e "    ${GREEN}HTTP ${http_code}${RESET}  ${DIM}${timing}s${RESET}"
        else
            echo -e "    ${YELLOW}HTTP ${http_code}${RESET}  ${DIM}${timing}s${RESET}"
        fi
        PASS=$((PASS + 1))  # any proxied response (including 4xx/5xx) counts as captured
    else
        echo -e "    ${RED}FAILED (no response / proxy unreachable)${RESET}"
        FAIL=$((FAIL + 1))
    fi

    sleep "${DELAY}"
}

# send_with_body LABEL URL CONTENT_TYPE BODY [extra curl args...]
send_with_body() {
    local label="$1"
    local url="$2"
    local content_type="$3"
    local body="$4"
    shift 4
    send "${label}" "${url}" \
        -X POST \
        -H "Content-Type: ${content_type}" \
        --data "${body}" \
        "$@"
}

# ── Preflight ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}JoesProxy Smoke Test${RESET}"
echo -e "  Proxy:   ${PROXY}"
echo -e "  Delay:   ${DELAY}s between requests"
echo -e "  Timeout: ${TIMEOUT}s per request"
if [[ "${SKIP_CA_VERIFY}" == "1" ]]; then
    echo -e "  CA:      ${YELLOW}verification disabled (-k)  — HTTPS will be tunneled, not intercepted${RESET}"
else
    echo -e "  CA:      verification enabled  — ensure JoesProxy Root CA is trusted for HTTPS interception"
fi
echo ""

# Verify the proxy is reachable before running the full suite.
echo -e "${DIM}Checking proxy is reachable...${RESET}"
if ! curl --silent --proxy "${PROXY}" --max-time 5 --output /dev/null http://example.com; then
    echo -e "${RED}Proxy at ${PROXY} is not responding. Start the JoesProxy listener and try again.${RESET}"
    exit 1
fi
echo -e "${GREEN}Proxy is up.${RESET}"

# ── Section 1: Plain HTTP ─────────────────────────────────────────────────────

section "1 · Plain HTTP — Session Capture Basics"

send "GET example.com (HTML)" \
    "http://example.com"

send "GET httpbin /get — echoes request as JSON" \
    "http://httpbin.org/get" \
    -H "X-Test-Header: joesproxy-smoke"

send "GET httpbin /headers — inspect captured request headers" \
    "http://httpbin.org/headers" \
    -H "Authorization: Bearer smoke-test-token" \
    -H "X-Custom-Client: JoesProxy"

send "HEAD request — no body" \
    "http://httpbin.org/get" \
    -X HEAD

send "GET with query string — path shown in Explorer" \
    "http://httpbin.org/get?filter=active&page=1&limit=20"

# ── Section 2: HTTP Status Codes ─────────────────────────────────────────────

section "2 · HTTP Status Codes"

send "200 OK" \
    "http://httpbin.org/status/200"

send "201 Created" \
    "http://httpbin.org/status/201"

send "301 Redirect (follows to 200)" \
    "http://httpbin.org/redirect/1" \
    --location

send "400 Bad Request" \
    "http://httpbin.org/status/400"

send "401 Unauthorized" \
    "http://httpbin.org/status/401"

send "404 Not Found" \
    "http://httpbin.org/status/404"

send "500 Internal Server Error" \
    "http://httpbin.org/status/500"

send "503 Service Unavailable" \
    "http://httpbin.org/status/503"

# ── Section 3: HTTP Methods ───────────────────────────────────────────────────

section "3 · HTTP Methods"

send_with_body \
    "POST JSON body — inspect request + response" \
    "http://httpbin.org/post" \
    "application/json" \
    '{"user":"joesproxy","action":"smoke_test","version":1}'

send_with_body \
    "PUT JSON body" \
    "http://httpbin.org/put" \
    "application/json" \
    '{"id":42,"status":"updated"}'

send_with_body \
    "PATCH JSON body" \
    "http://httpbin.org/patch" \
    "application/json" \
    '{"field":"value"}'

send "DELETE request" \
    "http://httpbin.org/delete" \
    -X DELETE

# ── Section 4: JSON Response Inspection ──────────────────────────────────────

section "4 · JSON Viewer — Folder / Raw / Prettified"

send "Flat JSON object" \
    "http://jsonplaceholder.typicode.com/posts/1"

send "JSON array (100 items) — stress the Folder tree" \
    "http://jsonplaceholder.typicode.com/posts"

send "Nested JSON — users with address + geo + company" \
    "http://jsonplaceholder.typicode.com/users"

send "JSON with null values and booleans" \
    "http://httpbin.org/json"

send_with_body \
    "Echo POST body as JSON — verify round-trip" \
    "http://httpbin.org/anything" \
    "application/json" \
    '{"nested":{"array":[1,2,3],"flag":true,"nothing":null},"root":"value"}'

# ── Section 5: HTTPS Interception ────────────────────────────────────────────

section "5 · HTTPS — CONNECT Tunneling and Interception"

send "HTTPS GET example.com — CONNECT tunnel" \
    "https://example.com"

send "HTTPS JSON — jsonplaceholder over TLS" \
    "https://jsonplaceholder.typicode.com/todos/1"

send "HTTPS POST — inspect intercepted request + body" \
    "https://httpbin.org/post" \
    -X POST \
    -H "Content-Type: application/json" \
    --data '{"https":true,"intercepted":"yes"}'

send "HTTPS with Authorization header" \
    "https://httpbin.org/bearer" \
    -H "Authorization: Bearer smoke-https-token"

send "HTTPS redirect chain" \
    "https://httpbin.org/redirect/2" \
    --location

# ── Section 6: Image Responses — Media Inspection ────────────────────────────

section "6 · Media — Image Inspection"

send "PNG image response" \
    "http://httpbin.org/image/png"

send "JPEG image response" \
    "http://httpbin.org/image/jpeg"

send "WebP image response" \
    "http://httpbin.org/image/webp"

send "SVG image — Content-Type: image/svg+xml" \
    "http://httpbin.org/image/svg"

# ── Section 7: HLS Manifests — Media Inspection ──────────────────────────────

section "7 · Media — HLS Manifest Analysis"

send "Apple HLS sample — master playlist (m3u8)" \
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"

send "Apple HLS — 200kbps variant playlist" \
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear1/prog_index.m3u8"

send "Apple HLS — 400kbps variant playlist" \
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear2/prog_index.m3u8"

send "Apple HLS advanced sample — master playlist" \
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"

# ── Section 8: Multiple Hosts — Explorer Grouping ────────────────────────────

section "8 · Multiple Hosts — Explorer By-Host Grouping"

for host in \
    "http://jsonplaceholder.typicode.com/albums/1" \
    "http://jsonplaceholder.typicode.com/photos/1" \
    "http://jsonplaceholder.typicode.com/todos/1" \
    "http://httpbin.org/uuid" \
    "http://httpbin.org/user-agent" \
    "http://example.com" \
    "https://jsonplaceholder.typicode.com/comments/1" \
    "https://httpbin.org/get"; do
    send "${host}" "${host}"
done

# ── Section 9: Timing and Delays ─────────────────────────────────────────────

section "9 · Response Timing — Slow Requests"

send "1-second server delay — test timing capture" \
    "http://httpbin.org/delay/1"

send "2-second server delay" \
    "http://httpbin.org/delay/2"

# ── Section 10: Large Responses ──────────────────────────────────────────────

section "10 · Large Responses — JSON Viewer Performance"

send "1000-byte random bytes (binary)" \
    "http://httpbin.org/bytes/1000"

send "Large JSON — /posts repeated query (via httpbin anything)" \
    "http://jsonplaceholder.typicode.com/comments"

send "httpbin /stream-bytes 4096 — chunked transfer" \
    "http://httpbin.org/stream-bytes/4096"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Results${RESET}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
echo -e "  Total:  ${TOTAL}"
echo -e "  ${GREEN}Captured: ${PASS}${RESET}"
echo -e "  ${RED}Failed:   ${FAIL}${RESET}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
    echo -e "${YELLOW}Some requests did not reach the proxy. Check:${RESET}"
    echo -e "  - JoesProxy listener is started (port ${PROXY_PORT})"
    echo -e "  - No firewall blocking 127.0.0.1:${PROXY_PORT}"
    echo -e "  - For HTTPS interception: JoesProxy Root CA is installed and trusted"
    echo -e "  - Run with SKIP_CA_VERIFY=1 to bypass CA checks (HTTPS will tunnel, not intercept)"
    exit 1
fi

echo -e "${GREEN}All requests captured. Open JoesProxy and verify:${RESET}"
echo -e "  - Session list shows ${TOTAL} entries"
echo -e "  - JSON viewer (Folder / Raw / Prettified) works on JSON responses"
echo -e "  - Media Info badge appears on image and m3u8 sessions"
echo -e "  - HTTPS sessions show as intercepted (not tunneled) if CA is trusted"
echo -e "  - Explorer groups traffic by host correctly"
echo ""
