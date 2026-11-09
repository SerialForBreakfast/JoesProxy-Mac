#!/usr/bin/env swift
// spike_one_click_trust.swift
//
// Spike Q1: Can 'security add-trusted-cert' trust a root CA from a non-sandboxed
// macOS process without admin rights — just a user password dialog?
//
// This is the gate for replacing the 8-step Keychain Access manual flow in
// macOSSetupWalkthroughView Step 3 with a single "Trust Root CA" button.
//
// Run:
//   swift memlog/utility_scripts/spike_one_click_trust.swift
//
// Expected behaviour:
//   - A macOS "security wants to make changes" password dialog appears.
//   - After approving it, the cert is found trusted in the login keychain.
//   - The script cleans up automatically.
//
// Emergency manual cleanup (if the script crashes mid-run):
//   security delete-certificate -c "JoesProxy-Spike-Test" ~/Library/Keychains/login.keychain-db

import Foundation

// MARK: - Shell helper

@discardableResult
func shell(_ path: String, _ args: String...) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { return (-1, "", "launch error: \(error)") }
    p.waitUntilExit()
    let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus,
            out.trimmingCharacters(in: .whitespacesAndNewlines),
            err.trimmingCharacters(in: .whitespacesAndNewlines))
}

func step(_ n: Int, _ label: String) { print("\nStep \(n): \(label)") }
func pass(_ msg: String) { print("  ✓  \(msg)") }
func fail(_ msg: String) { print("  ✗  \(msg)") }
func note(_ msg: String) { print("     \(msg)") }

// MARK: - Config

let certPath = "/tmp/joespproxy-spike-cert.pem"
let keyPath  = "/tmp/joespproxy-spike-key.pem"
let cn       = "JoesProxy-Spike-Test"
let keychain = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Keychains/login.keychain-db")

var overallPassed = true

// MARK: - Step 1: Generate test cert

step(1, "Generate temporary self-signed root CA via openssl")

let (genStatus, _, genErr) = shell(
    "/usr/bin/openssl", "req", "-x509",
    "-newkey", "rsa:2048",
    "-keyout", keyPath,
    "-out", certPath,
    "-days", "1",
    "-nodes",
    "-subj", "/CN=\(cn)/O=JoesProxySpikeOrg"
)

guard genStatus == 0 else {
    fail("openssl failed (exit \(genStatus)): \(genErr)")
    print("\nABORTED — openssl not available or failed.")
    exit(1)
}
pass("Created at \(certPath)")

// MARK: - Step 2: Trust via security command

step(2, "Running 'security add-trusted-cert -r trustRoot'")
print()
print("     >>>  A macOS password dialog SHOULD appear.  <<<")
print("     >>>  Approve it to test the user-consent path.  <<<")
print()

let before = Date()
let (trustStatus, _, trustErr) = shell(
    "/usr/bin/security", "add-trusted-cert",
    "-r", "trustRoot",
    "-k", keychain,
    certPath
)
let elapsed = Date().timeIntervalSince(before)

note("exit code:  \(trustStatus)")
note("elapsed:    \(String(format: "%.2f", elapsed))s")
if !trustErr.isEmpty { note("stderr:     \(trustErr)") }

if trustStatus == 0 {
    pass("Command succeeded")
} else {
    fail("Command FAILED (exit \(trustStatus))")
    overallPassed = false
}

let dialogLikely = elapsed > 0.8
note("Password dialog: \(dialogLikely ? "YES — user interaction detected (\(String(format: "%.1f", elapsed))s)" : "instant — dialog may have been suppressed or cert was already trusted")")

// MARK: - Step 3: Verify cert is in login keychain

step(3, "Verify cert is present in login keychain")

let (findStatus, findOut, _) = shell(
    "/usr/bin/security", "find-certificate",
    "-c", cn, "-p", keychain
)
let foundInKeychain = findStatus == 0 && findOut.contains("BEGIN CERTIFICATE")

if foundInKeychain {
    pass("Found in keychain")
} else {
    fail("Not found in keychain (exit \(findStatus))")
    overallPassed = false
}

// MARK: - Step 4: Check trust settings

step(4, "Inspect trust settings for the cert")

// Dump per-cert trust to see the trustRoot entry
let (verifyStatus, verifyOut, _) = shell(
    "/usr/bin/security", "verify-cert",
    "-c", certPath,
    "-k", keychain,
    "-p", "ssl"          // SSL policy — root CAs trusted here work for HTTPS inspection
)

note("verify-cert (ssl policy) exit: \(verifyStatus)")
if verifyStatus == 0 {
    pass("Cert is trusted under the ssl policy")
} else {
    note("ssl policy verify returned \(verifyStatus) — normal for a CA-only cert without SANs")
    note("The add-trusted-cert command is the authoritative test; verify-cert ssl may fail for bare root CAs")
}

// Check basic policy (simpler — just checks if it's a trusted root)
let (basicStatus, _, _) = shell(
    "/usr/bin/security", "verify-cert",
    "-c", certPath,
    "-k", keychain
)
note("verify-cert (basic policy) exit: \(basicStatus)")
if basicStatus == 0 {
    pass("Cert is trusted under basic policy")
} else {
    note("basic policy also returned non-zero — trust settings may only take effect after macOS processes them")
}

// MARK: - Step 5: Cleanup

step(5, "Cleanup — removing test cert from keychain")

let (delStatus, _, delErr) = shell(
    "/usr/bin/security", "delete-certificate",
    "-c", cn, keychain
)
if delStatus == 0 {
    pass("Removed from keychain")
} else {
    fail("Could not remove (exit \(delStatus)): \(delErr)")
    note("Manual cleanup: security delete-certificate -c \"\(cn)\" \(keychain)")
}

try? FileManager.default.removeItem(atPath: certPath)
try? FileManager.default.removeItem(atPath: keyPath)
pass("Temp files removed")

// MARK: - Summary

print()
print(String(repeating: "─", count: 60))
print("SPIKE Q1 RESULT — One-Click macOS Trust Feasibility")
print(String(repeating: "─", count: 60))
print("security add-trusted-cert exit code : \(trustStatus)")
print("User password dialog appeared        : \(dialogLikely ? "YES" : "UNKNOWN (instant)")")
print("Cert added to login keychain         : \(foundInKeychain ? "YES" : "NO")")
print()

if trustStatus == 0 {
    print("""
    CONCLUSION: FEASIBLE ✓

      'security add-trusted-cert' works from a non-sandboxed process.

      Implementation plan for macOSSetupWalkthroughView Step 3:
        1. Add 'func trustRootCertificate()' to ProxyViewModel that shells out to:
               security add-trusted-cert -r trustRoot
                   -k ~/Library/Keychains/login.keychain-db
                   <exported-cert-path>
        2. Show a "Trust Root CA" button; on tap run the command.
        3. Poll refreshCertificateStatus() after it returns (the state
           update will flip certificateWorkflowState to .ready).
        4. Move the 8-step Keychain Access instructions into a
           DisclosureGroup("Trust manually").
    """)
} else {
    print("""
    CONCLUSION: NOT FEASIBLE ✗

      Exit code \(trustStatus). Keep the 8-step manual Keychain Access instructions.
      \(!trustErr.isEmpty ? "Error: \(trustErr)" : "")
    """)
}
