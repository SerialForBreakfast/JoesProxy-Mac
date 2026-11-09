//
//  DataProvenanceWatermarker.swift
//  JoesProxy
//
//  In-flight response interceptor and synthetic JSON watermark injector.
//

import Foundation

actor ProvenanceRegistry {
    static let shared = ProvenanceRegistry()

    private var registeredTokens: [String: DataLineageNode] = [:]

    func register(token: String, node: DataLineageNode) {
        registeredTokens[token] = node
    }

    func lookup(token: String) -> DataLineageNode? {
        registeredTokens[token]
    }

    func allTokens() -> [String: DataLineageNode] {
        registeredTokens
    }

    func clear() {
        registeredTokens.removeAll()
    }
}

enum DataProvenanceWatermarker {

    /// Injects synthetic provenance watermarks into a JSON response body according to a rule.
    static func watermark(
        jsonData: Data,
        rule: DataWatermarkRule,
        sessionID: UUID,
        endpointURL: String,
        timestamp: Date = Date()
    ) -> (modifiedData: Data, injectedTokens: [String: DataLineageNode]) {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: [.mutableContainers, .fragmentsAllowed]) else {
            return (jsonData, [:])
        }

        var injected: [String: DataLineageNode] = [:]
        let shortID = sessionID.uuidString.prefix(6).lowercased()

        let modifiedObject = processJSON(
            jsonObject,
            rule: rule,
            path: "$",
            sessionID: sessionID,
            endpointURL: endpointURL,
            timestamp: timestamp,
            shortID: String(shortID),
            injected: &injected
        )

        guard let outputData = try? JSONSerialization.data(withJSONObject: modifiedObject, options: [.prettyPrinted, .sortedKeys]) else {
            return (jsonData, [:])
        }

        // Register in Provenance Registry
        Task {
            for (token, node) in injected {
                await ProvenanceRegistry.shared.register(token: token, node: node)
            }
        }

        return (outputData, injected)
    }

    // MARK: - Recursive JSON Traversal

    private static func processJSON(
        _ value: Any,
        rule: DataWatermarkRule,
        path: String,
        sessionID: UUID,
        endpointURL: String,
        timestamp: Date,
        shortID: String,
        injected: inout [String: DataLineageNode]
    ) -> Any {
        if var dict = value as? [String: Any] {
            // Check for property injection
            if case .property(let key, let val) = rule.strategy {
                if rule.targetKeypaths.isEmpty || rule.targetKeypaths.contains(path) {
                    dict[key] = val
                    let token = val
                    injected[token] = DataLineageNode(
                        sessionID: sessionID,
                        endpointURL: endpointURL,
                        httpMethod: "GET",
                        timestamp: timestamp,
                        keypath: "\(path).\(key)",
                        value: val
                    )
                }
            }

            for (k, v) in dict {
                let curPath = "\(path).\(k)"
                dict[k] = processJSON(
                    v,
                    rule: rule,
                    path: curPath,
                    sessionID: sessionID,
                    endpointURL: endpointURL,
                    timestamp: timestamp,
                    shortID: shortID,
                    injected: &injected
                )
            }
            return dict
        } else if var arr = value as? [Any] {
            for idx in 0..<arr.count {
                let curPath = "\(path)[\(idx)]"
                arr[idx] = processJSON(
                    arr[idx],
                    rule: rule,
                    path: curPath,
                    sessionID: sessionID,
                    endpointURL: endpointURL,
                    timestamp: timestamp,
                    shortID: shortID,
                    injected: &injected
                )
            }
            return arr
        } else if let str = value as? String {
            // Check if this path should be watermarked
            let shouldWatermark: Bool
            if rule.targetKeypaths.isEmpty {
                shouldWatermark = true
            } else {
                shouldWatermark = rule.targetKeypaths.contains(path)
            }

            if shouldWatermark {
                let token: String
                let modifiedStr: String
                switch rule.strategy {
                case .suffix(let tag):
                    token = "\(tag)_\(shortID)"
                    modifiedStr = "\(str)__\(token)"
                case .prefix(let tag):
                    token = "\(tag)_\(shortID)"
                    modifiedStr = "\(token)__\(str)"
                case .autoAllStrings(let tagPrefix):
                    let sanitizedPath = path.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "[", with: "_").replacingOccurrences(of: "]", with: "")
                    token = "JP_\(tagPrefix)_\(shortID)\(sanitizedPath)"
                    modifiedStr = "\(str)__[\(token)]"
                case .property:
                    return str
                }

                injected[token] = DataLineageNode(
                    sessionID: sessionID,
                    endpointURL: endpointURL,
                    httpMethod: "GET",
                    timestamp: timestamp,
                    keypath: path,
                    value: str
                )
                return modifiedStr
            }
        }
        return value
    }
}
