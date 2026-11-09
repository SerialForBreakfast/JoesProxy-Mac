#!/usr/bin/env bash
# proxy_perf_test.sh
#
# Reproducible performance test harness for JoesProxy.
#
# Routes traffic through the proxy so every request appears in the session table,
# giving deterministic, comparable runs for before/after profiling.
#
# USAGE
#   ./proxy_perf_test.sh [scenario]
#
#   Scenarios:
#     burst-small    50 concurrent small JSON requests (~1 KB each)
#     burst-medium   20 concurrent medium responses (~50 KB each)
#     burst-large     5 concurrent large binary responses (~1 MB each)
#     sustained      100 sequential requests at ~5/sec over 20 seconds
#     all            runs all four scenarios in sequence (default)
#
# REQUIREMENTS
#   - JoesProxy running with proxy on localhost:9090
#   - curl installed (ships with macOS)
#   - The proxy root CA trusted by curl OR use -k (skips cert verify, fine for perf testing)
#
# HOW TO USE WITH INSTRUMENTS
#   1. Start JoesProxy and confirm the proxy is running (port 9090).
#   2. Open Instruments → File → New → Time Profiler (also attach os_signpost instrument).
#   3. Start recording.
#   4. In a terminal: ./proxy_perf_test.sh all
#   5. Stop recording after the script finishes.
#   6. In Instruments filter subsystem "com.JoesProxyApp.Capture" to see signpost lanes.
#
# WHY curl INSTEAD OF A REAL APP
#   Real-app traffic is non-deterministic: response sizes, timing, and request counts vary
#   between runs, making before/after comparisons unreliable. This script gives:
#     - Fixed session count per scenario (easy to verify in the session table)
#     - Reproducible response sizes (controlled by the endpoint)
#     - Known concurrency levels (--parallel --parallel-max)
#   Use a real client app for real-world validation; use this script for regression testing.
#
# NOTE: curl routes HTTPS requests through the proxy as CONNECT tunnels, which JoesProxy
# intercepts and decrypts. The -k flag skips end-to-end certificate validation on the
# curl side (the proxy's own cert is still verified by curl for the tunnel, but the leaf
# cert the proxy presents for the upstream host is not). For perf testing this is fine.

set -euo pipefail

PROXY="http://localhost:9090"

# In-repo scratch dir for curl config files — inspectable on failure, never /var/folders.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRATCH_DIR="$SCRIPT_DIR/../../memlog/.test-scratch/proxy_perf_test"
mkdir -p "$SCRATCH_DIR"

# ── helpers ──────────────────────────────────────────────────────────────────

check_proxy() {
    echo "→ Checking proxy reachability on localhost:9090 ..."
    # Use nc -z to check the port is open — do NOT send an HTTP GET directly to the proxy
    # port without the -x flag, because the proxy would try to forward the request back to
    # itself (localhost:9090), causing a recursive forwarding loop and thousands of fake sessions.
    if ! nc -z localhost 9090 2>/dev/null; then
        echo "ERROR: Nothing is listening on localhost:9090."
        echo "  Make sure JoesProxy is running with the proxy started on port 9090."
        exit 1
    fi
    echo "  Port 9090 is open. Testing HTTPS interception through proxy..."
    if ! curl -s -k -x "$PROXY" --connect-timeout 5 -o /dev/null https://httpbin.org/status/200 2>/dev/null; then
        echo "ERROR: Could not reach httpbin.org through the proxy."
        echo "  Verify that HTTPS inspection is enabled and the root CA is trusted by curl."
        exit 1
    fi
    echo "  Proxy OK."
}

log_scenario() {
    local scenario=$1 event=$2 extra=${3:-""}
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$ts PERF scenario=$scenario event=$event $extra"
    # Also emit to macOS unified log so markers appear in the Instruments os_log lane.
    /usr/bin/logger -t "JoesProxyPerfTest" "$ts PERF scenario=$scenario event=$event $extra" 2>/dev/null || true
}

# ── scenario 1: burst-small ───────────────────────────────────────────────
# 50 concurrent requests, ~1 KB response each.
# Target: tests coalescing — many appends + updates arrive in the same 75ms window.
scenario_burst_small() {
    local count=50
    local start=$SECONDS
    log_scenario "burst-small" "start" "count=$count"

    local cfg="$SCRATCH_DIR/curl-config-burst-small-$$.txt"
    for i in $(seq 1 $count); do
        echo "url = https://httpbin.org/json" >> "$cfg"
        echo "-k" >> "$cfg"
        echo "-s" >> "$cfg"
        echo "-o /dev/null" >> "$cfg"
        echo "-x $PROXY" >> "$cfg"
        echo "" >> "$cfg"
    done

    curl --parallel --parallel-max 20 --config "$cfg"
    rm -f "$cfg"

    log_scenario "burst-small" "end" "count=$count elapsed=$((SECONDS - start))s"
}

# ── scenario 2: burst-medium ──────────────────────────────────────────────
# 20 concurrent requests, ~50 KB response each (compressed image or JSON array).
# Target: tests response accumulation without hitting the body-bytes limit.
scenario_burst_medium() {
    local count=20
    local start=$SECONDS
    log_scenario "burst-medium" "start" "count=$count"

    local cfg="$SCRATCH_DIR/curl-config-burst-medium-$$.txt"
    for i in $(seq 1 $count); do
        echo "url = https://httpbin.org/bytes/51200" >> "$cfg"
        echo "-k" >> "$cfg"
        echo "-s" >> "$cfg"
        echo "-o /dev/null" >> "$cfg"
        echo "-x $PROXY" >> "$cfg"
        echo "" >> "$cfg"
    done

    curl --parallel --parallel-max 10 --config "$cfg"
    rm -f "$cfg"

    log_scenario "burst-medium" "end" "count=$count elapsed=$((SECONDS - start))s"
}

# ── scenario 3: burst-large ───────────────────────────────────────────────
# 5 concurrent requests, ~1 MB response each.
# Target: tests body accumulation and the 250 MB body-bytes retention limit.
scenario_burst_large() {
    local count=5
    local start=$SECONDS
    log_scenario "burst-large" "start" "count=$count"

    local cfg="$SCRATCH_DIR/curl-config-burst-large-$$.txt"
    for i in $(seq 1 $count); do
        echo "url = https://httpbin.org/bytes/1048576" >> "$cfg"
        echo "-k" >> "$cfg"
        echo "-s" >> "$cfg"
        echo "-o /dev/null" >> "$cfg"
        echo "-x $PROXY" >> "$cfg"
        echo "" >> "$cfg"
    done

    curl --parallel --parallel-max 5 --config "$cfg"
    rm -f "$cfg"

    log_scenario "burst-large" "end" "count=$count elapsed=$((SECONDS - start))s"
}

# ── scenario 4: sustained ─────────────────────────────────────────────────
# 100 sequential requests at a steady ~5/sec rate.
# Target: tests the incremental refresh path under a sustained but not bursty load.
# Also good for checking if the 75ms debounce is coalescing effectively.
scenario_sustained() {
    local count=100
    local start=$SECONDS
    local success=0
    log_scenario "sustained" "start" "count=$count rate=5/sec"

    for i in $(seq 1 $count); do
        code=$(curl -s -k -x "$PROXY" -o /dev/null -w '%{http_code}' "https://httpbin.org/json" 2>/dev/null || echo "000")
        if [ "$code" = "200" ]; then
            success=$((success + 1))
        fi
        sleep 0.2
    done

    log_scenario "sustained" "end" "success=$success/$count elapsed=$((SECONDS - start))s"
}

# ── scenario 5: mixed ─────────────────────────────────────────────────────
# Mix of different endpoint types to simulate varied API traffic.
# 30 requests: JSON, binary, redirect, delay, headers.
scenario_mixed() {
    local count=30
    local start=$SECONDS
    log_scenario "mixed" "start" "count=$count"

    local cfg="$SCRATCH_DIR/curl-config-mixed-$$.txt"
    for i in $(seq 1 6); do
        for endpoint in "/json" "/headers" "/bytes/8192" "/status/200" "/user-agent"; do
            echo "url = https://httpbin.org${endpoint}" >> "$cfg"
            echo "-k" >> "$cfg"
            echo "-s" >> "$cfg"
            echo "-o /dev/null" >> "$cfg"
            echo "-x $PROXY" >> "$cfg"
            echo "" >> "$cfg"
        done
    done

    curl --parallel --parallel-max 10 --config "$cfg"
    rm -f "$cfg"

    log_scenario "mixed" "end" "count=$count elapsed=$((SECONDS - start))s"
}

# ── main ──────────────────────────────────────────────────────────────────

SCENARIO="${1:-all}"

echo ""
echo "JoesProxy Performance Test"
echo "Proxy: $PROXY"
echo "Scenario: $SCENARIO"

check_proxy

case "$SCENARIO" in
    burst-small)  scenario_burst_small ;;
    burst-medium) scenario_burst_medium ;;
    burst-large)  scenario_burst_large ;;
    sustained)    scenario_sustained ;;
    mixed)        scenario_mixed ;;
    all)
        log_scenario "all" "start"
        scenario_burst_small
        sleep 2
        scenario_burst_medium
        sleep 2
        scenario_burst_large
        sleep 2
        scenario_sustained
        sleep 2
        scenario_mixed
        log_scenario "all" "end" "total_expected=205"
        ;;
    *)
        echo "Unknown scenario: $SCENARIO"
        echo "Valid: burst-small, burst-medium, burst-large, sustained, mixed, all"
        exit 1
        ;;
esac
