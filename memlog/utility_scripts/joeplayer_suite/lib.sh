#!/usr/bin/env bash
# Shared helpers for JoePlayer trial suite scripts.
set -euo pipefail

JOEPLAYER_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$JOEPLAYER_SUITE_DIR/../../.." && pwd)"
FIXTURES_HLS="$ROOT_DIR/Fixtures/HLS"
JOEPLAYER_BUNDLE_ID="com.showblender.JoesProxyPlayer"
COMPANION_PROJECT="$ROOT_DIR/Companion/JoesProxyCompanion/JoesProxyCompanion.xcodeproj"
JOEPLAYER_SCHEME="JoesProxyPlayer"
VERSION_XCCONFIG="$ROOT_DIR/Config/Version.xcconfig"

log() {
  printf '[joeplayer-suite] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "Missing required command: $name"
}

suite_preflight() {
  require_cmd jq
  require_cmd curl
  require_cmd xcrun
  resolve_joesproxyctl >/dev/null || die "joesproxyctl not found. Build JoesProxy or set JOESPROXYCTL."
}

resolve_joesproxyctl() {
  if [[ -n "${JOESPROXYCTL:-}" && -x "$JOESPROXYCTL" ]]; then
    printf '%s\n' "$JOESPROXYCTL"
    return 0
  fi
  local candidate
  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$ROOT_DIR/build" "$ROOT_DIR/DerivedData" -name joesproxyctl -type f 2>/dev/null | head -5)
  local app_cli="/Applications/JoesProxy.app/Contents/MacOS/joesproxyctl"
  if [[ -x "$app_cli" ]]; then
    printf '%s\n' "$app_cli"
    return 0
  fi
  return 1
}

marketing_version() {
  if [[ -f "$VERSION_XCCONFIG" ]]; then
    grep -m1 '^MARKETING_VERSION' "$VERSION_XCCONFIG" | sed 's/#.*//;s/^[^=]*= *//;s/^[[:space:]]*//;s/[[:space:]]*$//'
    return 0
  fi
  printf 'development\n'
}

joesproxyctl_json() {
  local ctl
  ctl="$(resolve_joesproxyctl)"
  # Discard Cache.db noise on stderr unless a caller redirected JOEPLAYER_TRIAL_STDERR.
  "$ctl" "$@" --json 2>"${JOEPLAYER_TRIAL_STDERR:-/dev/null}"
}

resolve_simulator_udid() {
  # Prefer Booted devices with the highest runtimeVersion when names collide.
  local name="${1:-iPhone 17 Pro}"
  xcrun simctl list devices available -j \
    | jq -r --arg name "$name" '
      [.devices | to_entries[] | .value[]
        | select(.isAvailable == true and .name == $name)
        | {
            udid,
            state,
            runtimeVersion: (.runtimeVersion // "0"),
            booted: (if .state == "Booted" then 1 else 0 end)
          }]
      | sort_by(.booted, .runtimeVersion) | reverse | .[0].udid // empty
    '
}

simulator_runtime_version() {
  local udid="$1"
  xcrun simctl list devices -j \
    | jq -r --arg udid "$udid" '.devices | to_entries[] | .value[] | select(.udid == $udid) | .runtimeVersion // empty' \
    | head -1
}

simulator_app_installed() {
  local udid="$1"
  xcrun simctl get_app_container "$udid" "$JOEPLAYER_BUNDLE_ID" >/dev/null 2>&1
}

find_joeplayer_build_product() {
  local derived
  derived="$(find "$ROOT_DIR/build" "$ROOT_DIR/DerivedData" \
    -path '*Debug-iphonesimulator/JoesProxyPlayer.app' -type d 2>/dev/null | head -1)"
  if [[ -n "$derived" && -d "$derived" ]]; then
    printf '%s\n' "$derived"
    return 0
  fi
  derived="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*Debug-iphonesimulator/JoesProxyPlayer.app' -type d 2>/dev/null | head -1)"
  if [[ -n "$derived" && -d "$derived" ]]; then
    printf '%s\n' "$derived"
    return 0
  fi
  return 1
}

proxy_port_from_status() {
  local status_json
  status_json="$(joesproxyctl_json status 2>/dev/null || true)"
  jq -r '.result.payload.proxyPort // .result.proxyPort // .result.payload.port // 9090' <<<"$status_json"
}

primary_network_service() {
  if networksetup -listallnetworkservices 2>/dev/null | grep -qx 'Wi-Fi'; then
    printf 'Wi-Fi\n'
    return 0
  fi
  networksetup -listallnetworkservices 2>/dev/null | grep -v '^An asterisk' | head -1
}

install_joesproxy_ca_on_simulator() {
  local udid="$1"
  local cert_dir="$ROOT_DIR/memlog/joeplayer-trials/.scratch"
  local cert_pem="$cert_dir/joesproxy-root-ca.pem"
  mkdir -p "$cert_dir"

  if [[ ! -s "$cert_pem" ]]; then
    if security find-certificate -c "JoesProxy Root CA" -p >"$cert_pem" 2>/dev/null \
      && [[ -s "$cert_pem" ]]; then
      log "Exported JoesProxy Root CA from login keychain"
    elif curl -fsS --max-time 5 "http://127.0.0.1:8765/cert" -o "$cert_dir/joesproxy-root-ca.cer" 2>/dev/null; then
      openssl x509 -inform DER -in "$cert_dir/joesproxy-root-ca.cer" -out "$cert_pem" 2>/dev/null \
        || openssl x509 -in "$cert_dir/joesproxy-root-ca.cer" -out "$cert_pem" 2>/dev/null \
        || true
    fi
  fi

  if [[ ! -s "$cert_pem" ]]; then
    log "WARNING: could not export JoesProxy root CA — install manually (JoePlayer Cert Setup or simctl keychain add-root-cert)"
    return 0
  fi

  log "Installing JoesProxy root CA on simulator $udid"
  if ! xcrun simctl keychain "$udid" add-root-cert "$cert_pem" >/dev/null 2>&1; then
    log "WARNING: simctl keychain add-root-cert failed (may already be installed)"
  fi
}

enable_macos_proxy_for_simulator() {
  local port="${1:-9090}"
  local service
  service="$(primary_network_service)"
  [[ -n "$service" ]] || die "No network service for system proxy"

  local restore_file="${JOEPLAYER_PROXY_RESTORE_FILE:-$ROOT_DIR/memlog/joeplayer-trials/.scratch/proxy-restore.env}"
  mkdir -p "$(dirname "$restore_file")"
  local web_enabled secure_enabled web_server web_port secure_server secure_port
  web_enabled="$(networksetup -getwebproxy "$service" 2>/dev/null | awk -F': ' '/^Enabled/ {print $2; exit}')"
  secure_enabled="$(networksetup -getsecurewebproxy "$service" 2>/dev/null | awk -F': ' '/^Enabled/ {print $2; exit}')"
  web_server="$(networksetup -getwebproxy "$service" 2>/dev/null | awk -F': ' '/^Server/ {print $2; exit}')"
  web_port="$(networksetup -getwebproxy "$service" 2>/dev/null | awk -F': ' '/^Port/ {print $2; exit}')"
  secure_server="$(networksetup -getsecurewebproxy "$service" 2>/dev/null | awk -F': ' '/^Server/ {print $2; exit}')"
  secure_port="$(networksetup -getsecurewebproxy "$service" 2>/dev/null | awk -F': ' '/^Port/ {print $2; exit}')"
  cat >"$restore_file" <<EOF
SERVICE=$(printf '%q' "$service")
WEB_ENABLED=$(printf '%q' "$web_enabled")
SECURE_ENABLED=$(printf '%q' "$secure_enabled")
WEB_SERVER=$(printf '%q' "${web_server:-127.0.0.1}")
WEB_PORT=$(printf '%q' "${web_port:-9090}")
SECURE_SERVER=$(printf '%q' "${secure_server:-127.0.0.1}")
SECURE_PORT=$(printf '%q' "${secure_port:-9090}")
EOF
  export JOEPLAYER_PROXY_RESTORE_FILE="$restore_file"
  export JOEPLAYER_PROXY_SERVICE="$service"

  log "Enabling macOS system proxy on '$service' → 127.0.0.1:$port (Simulator inherits this)"
  networksetup -setwebproxy "$service" 127.0.0.1 "$port" off
  networksetup -setsecurewebproxy "$service" 127.0.0.1 "$port" off
  networksetup -setwebproxystate "$service" on
  networksetup -setsecurewebproxystate "$service" on
}

restore_macos_proxy() {
  local restore_file="${JOEPLAYER_PROXY_RESTORE_FILE:-}"
  local service="${JOEPLAYER_PROXY_SERVICE:-}"
  [[ -n "$restore_file" && -f "$restore_file" ]] || return 0
  # shellcheck disable=SC1090
  . "$restore_file"
  service="${SERVICE:-$service}"
  [[ -n "$service" ]] || return 0
  log "Restoring macOS system proxy on '$service'"
  if [[ "${WEB_ENABLED:-No}" == "Yes" ]]; then
    networksetup -setwebproxy "$service" "${WEB_SERVER:-127.0.0.1}" "${WEB_PORT:-9090}" off
    networksetup -setwebproxystate "$service" on
  else
    networksetup -setwebproxystate "$service" off
  fi
  if [[ "${SECURE_ENABLED:-No}" == "Yes" ]]; then
    networksetup -setsecurewebproxy "$service" "${SECURE_SERVER:-127.0.0.1}" "${SECURE_PORT:-9090}" off
    networksetup -setsecurewebproxystate "$service" on
  else
    networksetup -setsecurewebproxystate "$service" off
  fi
}

probe_proxy_routing() {
  local port="${1:-9090}"
  if curl -fsS --http1.1 -x "http://127.0.0.1:$port" --max-time 5 "http://example.com" -o /dev/null; then
    log "Proxy probe OK on 127.0.0.1:$port"
    return 0
  fi
  log "WARNING: proxy probe failed — ensure JoesProxy proxy is running on $port"
  return 1
}

boot_simulator_if_needed() {
  local udid="$1"
  local state
  state="$(xcrun simctl list devices -j | jq -r --arg udid "$udid" '.devices | to_entries[] | .value[] | select(.udid == $udid) | .state')"
  if [[ "$state" != "Booted" ]]; then
    log "Booting simulator $udid"
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b
  fi
}

build_and_install_joeplayer() {
  local udid="$1"
  log "Building JoePlayer for simulator"
  xcodebuild build \
    -project "$COMPANION_PROJECT" \
    -scheme "$JOEPLAYER_SCHEME" \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$ROOT_DIR/build/JoePlayerDerivedData" \
    CODE_SIGNING_ALLOWED=NO >/dev/null
  local app_path="$ROOT_DIR/build/JoePlayerDerivedData/Build/Products/Debug-iphonesimulator/JoesProxyPlayer.app"
  [[ -d "$app_path" ]] || die "JoePlayer build product missing at $app_path"
  xcrun simctl install "$udid" "$app_path"
}

ensure_joeplayer_installed() {
  local udid="$1"
  if simulator_app_installed "$udid"; then
    log "JoePlayer already installed on $udid"
    return 0
  fi
  local app_path=""
  if app_path="$(find_joeplayer_build_product)"; then
    log "Installing JoePlayer from $app_path onto $udid"
    xcrun simctl install "$udid" "$app_path"
  else
    build_and_install_joeplayer "$udid"
  fi
  simulator_app_installed "$udid" || die "JoePlayer failed to install on simulator $udid"
}

fixture_stream_url() {
  local run_id="$1"
  local lower
  lower="$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]')"
  printf 'https://fixture-%s.hls.joesproxy.invalid/master.m3u8\n' "$lower"
}

fixture_host() {
  local run_id="$1"
  local lower
  lower="$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]')"
  printf 'fixture-%s.hls.joesproxy.invalid\n' "$lower"
}

iso8601_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

append_ndjson_line() {
  local file="$1"
  local json="$2"
  printf '%s\n' "$json" >>"$file"
}
