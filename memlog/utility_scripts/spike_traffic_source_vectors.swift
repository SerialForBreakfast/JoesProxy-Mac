#!/usr/bin/env swift
// spike_traffic_source_vectors.swift
//
// Spike Q4: What filter should TrafficWatchVerifier use for each walkthrough's
// verify step, given TrafficSource.classify(clientAddress:userAgent:)?
//
// This script reproduces the classify() logic from TrafficSource.swift and
// exercises it with realistic test vectors, covering:
//   - Physical iOS/tvOS device (non-loopback proxy client address)
//   - iOS Simulator (loopback + iPhone UA)
//   - Mac browser (loopback + Macintosh UA)
//   - Tunneled HTTPS CONNECT (no User-Agent visible)
//
// Run:
//   swift memlog/utility_scripts/spike_traffic_source_vectors.swift
//
// Key insight this spike confirms:
//   For physical devices, clientAddress is the device's LAN IP (non-loopback)
//   regardless of protocol (HTTP or HTTPS CONNECT). So .device fires on both
//   plain HTTP and HTTPS tunnels from a real iPhone/iPad/Apple TV.
//   For loopback clients (Simulator, Mac), tunneled HTTPS has no User-Agent,
//   so it classifies as .unknown — verify steps for these MUST use HTTP.

import Foundation

// MARK: - TrafficSource (reproduced from TrafficSource.swift for standalone use)

enum TrafficSource: Equatable, CustomStringConvertible {
    case mac, simulator, device, unknown

    static func classify(clientAddress: String?, userAgent: String?) -> TrafficSource {
        guard let addr = clientAddress, !addr.isEmpty else { return .unknown }
        if !isLoopback(addr) { return .device }
        guard let ua = userAgent, !ua.isEmpty else { return .unknown }
        if ua.contains("iPhone") || ua.contains("iPad") || ua.contains("iPod") { return .simulator }
        if ua.contains("Macintosh") || ua.contains("Mac OS X") { return .mac }
        return .unknown
    }

    private static func isLoopback(_ a: String) -> Bool {
        a == "127.0.0.1" || a == "::1" || a == "0:0:0:0:0:0:0:1"
    }

    var description: String {
        switch self {
        case .mac: return "mac"
        case .simulator: return "simulator"
        case .device: return "device"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Test harness

var passes = 0, fails = 0

func check(
    _ label: String,
    address: String?,
    userAgent: String?,
    expect: TrafficSource,
    implication: String? = nil
) {
    let got = TrafficSource.classify(clientAddress: address, userAgent: userAgent)
    let ok  = got == expect
    ok ? (passes += 1) : (fails += 1)
    let sym = ok ? "✓" : "✗ FAIL"
    print("  \(sym)  \(label)")
    if !ok { print("       expected .\(expect), got .\(got)") }
    if let imp = implication { print("       → \(imp)") }
}

// MARK: - Physical iOS / tvOS device (non-loopback LAN address)

print("Physical iOS / tvOS device  (non-loopback client address)")
print("─────────────────────────────────────────────────────────")

check("HTTP  Safari iPhone UA",
      address: "192.168.1.42",
      userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15",
      expect: .device)

check("HTTP  Safari iPad UA",
      address: "10.0.0.5",
      userAgent: "Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
      expect: .device)

check("HTTPS CONNECT tunnel  (no UA)  —  device LAN address",
      address: "192.168.1.42",
      userAgent: nil,
      expect: .device,
      implication: "CONNECT from a physical device is still .device — clientAddress is the LAN IP, UA not needed.")

check("HTTPS CONNECT tunnel  (no UA)  —  different subnet",
      address: "10.0.1.99",
      userAgent: nil,
      expect: .device)

check("IPv6 link-local  (fe80::...)",
      address: "fe80::1a2b:3c4d",
      userAgent: nil,
      expect: .device,
      implication: "Link-local IPv6 is not a loopback address — classified as .device.")

// MARK: - iOS Simulator (loopback + iPhone-family UA)

print()
print("iOS Simulator  (loopback client address + iPhone/iPad UA)")
print("─────────────────────────────────────────────────────────")

check("HTTP  iPhone UA",
      address: "127.0.0.1",
      userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
      expect: .simulator)

check("HTTP  iPad UA",
      address: "::1",
      userAgent: "Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
      expect: .simulator)

check("HTTPS CONNECT tunnel  (no UA)  —  loopback",
      address: "127.0.0.1",
      userAgent: nil,
      expect: .unknown,
      implication: "⚠️  Tunneled CONNECT from Simulator has no UA → .unknown, not .simulator.")

// MARK: - Mac browser (loopback + Macintosh UA)

print()
print("Mac browser  (loopback client address + Macintosh UA)")
print("─────────────────────────────────────────────────────────")

check("HTTP  Safari macOS",
      address: "127.0.0.1",
      userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
      expect: .mac)

check("HTTP  Chrome macOS",
      address: "127.0.0.1",
      userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
      expect: .mac)

check("HTTP  Firefox macOS",
      address: "127.0.0.1",
      userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:125.0) Gecko/20100101 Firefox/125.0",
      expect: .mac)

check("HTTPS CONNECT tunnel  (no UA)  —  loopback",
      address: "127.0.0.1",
      userAgent: nil,
      expect: .unknown,
      implication: "⚠️  Tunneled CONNECT from Mac browser has no UA → .unknown, not .mac.")

// MARK: - Edge cases

print()
print("Edge cases")
print("─────────────────────────────────────────────────────────")

check("Nil clientAddress",
      address: nil,
      userAgent: "Mozilla/5.0 (iPhone; ...)",
      expect: .unknown)

check("Empty clientAddress",
      address: "",
      userAgent: "Mozilla/5.0 (Macintosh; ...)",
      expect: .unknown)

check("Loopback + curl UA (no OS keyword)",
      address: "127.0.0.1",
      userAgent: "curl/8.4.0",
      expect: .unknown)

check("Loopback + empty UA",
      address: "127.0.0.1",
      userAgent: "",
      expect: .unknown)

check("localhost string  (not a loopback IP — unusual but possible)",
      address: "localhost",
      userAgent: "Mozilla/5.0 (Macintosh; ...)",
      expect: .device,   // classify treats non-IP strings as non-loopback → .device
      implication: "Not a loopback IP string — treated as .device. Proxy should always pass numeric IP.")

// MARK: - Results

print()
print(String(repeating: "═", count: 62))
print("Results: \(passes) passed, \(fails) failed")
print()

if fails > 0 {
    print("⚠️  Some vectors failed — review TrafficSource.classify before building verify.")
    print()
}

// MARK: - Implications for TrafficWatchVerifier

print("SPIKE Q4 — TrafficWatchVerifier filter strategy per walkthrough")
print(String(repeating: "─", count: 62))
print("""

  Simulator verify
    Filter: .simulator
    Test URL: HTTP (e.g. captive.apple.com) — HTTPS CONNECT is .unknown.
    Implementation: existing SimulatorVerificationService; generalize into
    TrafficWatchVerifier with a .simulator source filter.

  iOS device verify
    Filter: .device
    Test URL: HTTP OR HTTPS both work — clientAddress is the device's LAN
    IP regardless of protocol, so .device fires without needing a UA.
    Instruction copy: "Open Safari on your iPhone and go to any site."

  tvOS device verify
    Filter: .device  (same as iOS — LAN IP → .device)
    Lower priority given streaming app pinning prevalence.

  macOS verify
    Filter: .mac
    Test URL: MUST be HTTP — HTTPS CONNECT from Mac is .unknown, not .mac.
    Implementation: open http://captive.apple.com (or similar HTTP-only URL)
    in the default browser, watch for .mac session.

  Key design rule for TrafficWatchVerifier:
    Accept a (TrafficSource) → Bool predicate so each verify step can
    supply its own filter without the verifier needing to know about
    walkthrough-level concepts.

    E.g.:
      Simulator: { $0 == .simulator }
      iOS/tvOS:  { $0 == .device }
      macOS:     { $0 == .mac }
""")

if fails > 0 { exit(1) }
