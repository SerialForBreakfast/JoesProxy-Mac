#!/usr/bin/env swift
// spike_profile_prefetch.swift
//
// Spike Q3: Does iOS Safari prefetch the .mobileconfig URL before the user
// intentionally taps "Install"? Are there multiple GETs, and how far apart?
//
// This determines whether ProfileHostingServer can reliably emit a "device
// downloaded the profile" signal for iOS walkthrough Step 1 confirmation,
// or whether prefetch GETs would create false positives.
//
// Run:
//   swift memlog/utility_scripts/spike_profile_prefetch.swift
//
// Then open the printed URL in Safari on an iPhone or iPad.
// Watch the request log. Press Ctrl-C when done to see the summary.
//
// Observe:
//   - 1 GET to /profile → no prefetch; single GET is safe to use as the signal.
//   - 2+ GETs to /profile close together (< 500ms) → prefetch present; need dedup.
//   - HEAD before GET → prefetch probe; ignore HEADs in the "downloaded" signal.
//   - What User-Agent Safari sends (useful for request filtering).

import Foundation
import Network

// MARK: - Request log

struct LogEntry {
    let seq: Int
    let time: Date
    let method: String
    let path: String
    let userAgent: String
    let accept: String
    let rawHeaders: [String: String]
}

var log: [LogEntry] = []
var seqCounter = 0

// MARK: - HTTP parsing

func parseRequest(_ text: String) -> (method: String, path: String, headers: [String: String]) {
    var method = "", path = ""
    var headers: [String: String] = [:]
    let lines = text.components(separatedBy: "\r\n")
    for (i, line) in lines.enumerated() {
        if i == 0 {
            let parts = line.components(separatedBy: " ")
            if parts.count >= 2 {
                method = parts[0]
                path = parts[1].components(separatedBy: "?").first ?? parts[1]
            }
        } else if line.isEmpty {
            break
        } else if let colon = line.firstIndex(of: ":") {
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }
    }
    return (method, path, headers)
}

func httpResponse(status: String, contentType: String, body: Data) -> Data {
    let header = [
        "HTTP/1.1 \(status)",
        "Content-Type: \(contentType)",
        "Content-Length: \(body.count)",
        "Connection: close",
        "", ""
    ].joined(separator: "\r\n")
    var r = Data(header.utf8)
    r.append(body)
    return r
}

// MARK: - Dummy .mobileconfig (minimal unsigned profile — enough to trigger Safari install flow)

let dummyProfile = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array/>
    <key>PayloadDisplayName</key>
    <string>JoesProxy Spike Test (safe to dismiss)</string>
    <key>PayloadIdentifier</key>
    <string>com.joesproxy.spike.prefetch</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>DEADBEEF-0000-0000-0000-000000000001</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
"""

let landingHTML = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>JoesProxy Prefetch Spike</title>
<style>
body { font-family:-apple-system,sans-serif; max-width:480px; margin:40px auto; padding:0 20px; }
a  { display:block; font-size:22px; margin:24px 0; color:#007aff; text-decoration:none; }
p  { color:#555; font-size:15px; }
</style>
</head>
<body>
<h2>JoesProxy Spike</h2>
<p>Tap the link below in Safari (do NOT long-press or Preview):</p>
<a href="/profile">▸ Install Trust Profile (.mobileconfig)</a>
<p style="font-size:13px;color:#999;margin-top:32px;">
  This is a spike test profile. You can dismiss the install dialog — we only
  care about the network requests, not the install itself.
</p>
</body>
</html>
"""

// MARK: - Connection handler

func handleConnection(_ conn: NWConnection) {
    conn.start(queue: .global(qos: .utility))
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
        let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
        let (method, path, headers) = parseRequest(text)
        let now = Date()
        seqCounter += 1

        let entry = LogEntry(
            seq: seqCounter,
            time: now,
            method: method,
            path: path,
            userAgent: headers["user-agent"] ?? "(none)",
            accept: headers["accept"] ?? "(none)",
            rawHeaders: headers
        )
        log.append(entry)

        // Live output
        let delta: String
        if log.count > 1 {
            let d = entry.time.timeIntervalSince(log[log.count - 2].time)
            delta = String(format: "+%.3fs", d)
        } else {
            delta = "    start"
        }

        print("[\(entry.seq)]  \(delta)    \(method.padding(toLength: 6, withPad: " ", startingAt: 0))  \(path)")
        print("       UA:      \(entry.userAgent)")
        print("       Accept:  \(entry.accept)")

        if path == "/profile" {
            let profileGETs = log.filter { $0.path == "/profile" && $0.method == "GET" }.count
            if profileGETs > 1 {
                let prev = log.last(where: { $0.path == "/profile" && $0.method == "GET" && $0.seq < entry.seq })
                let gap = prev.map { String(format: "%.0fms", entry.time.timeIntervalSince($0.time) * 1000) } ?? "?"
                print("       ⚠️  /profile GET #\(profileGETs) — \(gap) since last /profile GET")
            } else {
                print("       → /profile GET #\(profileGETs)")
            }
        }
        print()

        // Serve response
        let (body, ct): (Data, String) = {
            switch path {
            case "/profile":
                return (Data(dummyProfile.utf8), "application/x-apple-aspen-config")
            default:
                return (Data(landingHTML.utf8), "text/html; charset=utf-8")
            }
        }()

        let response = httpResponse(status: "200 OK", contentType: ct, body: body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Start NWListener

let portNum: NWEndpoint.Port = 8765
let listener = try NWListener(using: .tcp, on: portNum)

listener.newConnectionHandler = { conn in handleConnection(conn) }
listener.stateUpdateHandler = { state in
    if case .failed(let err) = state { print("Listener failed: \(err)"); exit(1) }
}
listener.start(queue: .global(qos: .utility))

// MARK: - Get LAN IP

func lanIP() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    p.arguments = ["getifaddr", "en0"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return out.isEmpty ? "127.0.0.1" : out
}

let ip = lanIP()
let port = portNum.rawValue

print("""
═══════════════════════════════════════════════════════════
spike_profile_prefetch  —  Safari prefetch detection
═══════════════════════════════════════════════════════════

Server listening on port \(port).

On your iPhone or iPad, open Safari and go to:

    http://\(ip):\(port)/

Then tap "Install Trust Profile".

Watch the output below. Each incoming request is logged with
its method, path, User-Agent, Accept header, and time delta
from the previous request.

Key questions:
  • Does a GET arrive before the user taps the link? (prefetch)
  • Does a HEAD arrive before the GET? (availability probe)
  • How many GETs to /profile appear per user tap?
  • How far apart are multiple GETs (if any)?

Press Ctrl-C when done to see the summary.
───────────────────────────────────────────────────────────

""")

// MARK: - SIGINT → summary

signal(SIGINT) { _ in
    print()
    print("═══════════════════════════════════════════════════════════")
    print("SPIKE Q3 SUMMARY — Profile download prefetch behaviour")
    print("═══════════════════════════════════════════════════════════")

    let totalRequests = log.count
    let profileGETs  = log.filter { $0.path == "/profile" && $0.method == "GET" }
    let profileHEADs = log.filter { $0.path == "/profile" && $0.method == "HEAD" }
    let rootGETs     = log.filter { $0.path == "/" }

    print("Total requests     : \(totalRequests)")
    print("GET /              : \(rootGETs.count)")
    print("GET /profile       : \(profileGETs.count)")
    print("HEAD /profile      : \(profileHEADs.count)")
    print()

    if profileGETs.count == 0 {
        print("No /profile GETs recorded — either the test wasn't run or")
        print("the device couldn't reach the server.")
    } else if profileGETs.count == 1 {
        print("RESULT: SINGLE GET — no prefetch detected.")
        print()
        print("CONCLUSION:")
        print("  Safe to use the first GET to /profile as the 'downloaded' signal.")
        print("  Emit profileDownloadedByDevice = true on the first /profile GET.")
    } else {
        let delta = profileGETs[1].time.timeIntervalSince(profileGETs[0].time)
        let deltaMs = Int(delta * 1000)
        print("RESULT: \(profileGETs.count) GETs to /profile")
        print("  Gap between GET 1 and GET 2: \(deltaMs)ms")
        print()
        if deltaMs < 500 {
            print("CONCLUSION: PREFETCH DETECTED (\(deltaMs)ms gap)")
            print()
            print("  Safari sends an extra GET before the user confirms install.")
            print("  Options for the 'downloaded' signal in ProfileHostingServer:")
            print()
            print("  A) Use only the LAST GET in a short burst (debounce ~500ms).")
            print("     Pro: accurate. Con: adds latency to the signal.")
            print()
            print("  B) Emit the signal on any GET, but show 'Downloading…' not 'Downloaded'")
            print("     until the user returns to the app (focus-regain already exists).")
            print("     Pro: simple. Con: slightly misleading during prefetch window.")
            print()
            print("  C) Check User-Agent: if UA indicates a prefetch (no UA, or bot UA),")
            print("     skip it. If UA is a real Safari UA, treat as intentional.")
        } else {
            print("CONCLUSION: GETs are spaced \(deltaMs)ms apart — likely separate user actions,")
            print("  not prefetch. Safe to emit the signal on the first GET.")
        }
    }

    if !profileHEADs.isEmpty {
        print()
        print("HEAD requests detected: \(profileHEADs.count)")
        print("  Ignore HEAD requests in the 'downloaded' signal — they are availability")
        print("  probes, not intentional downloads.")
    }

    print()
    exit(0)
}

dispatchMain()
