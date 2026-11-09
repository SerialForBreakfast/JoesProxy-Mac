//
//  AdXMLParser.swift
//  JoesProxy
//
//  Classifies and parses captured ad XML documents for Media Info.
//

import Foundation

enum AdXMLParser {
    /// Classifies ad XML using a bounded prefix of the captured body.
    static func classifyKind(in xml: String) -> AdXmlKind {
        let sample = xml.prefix(8_192)
        if sample.localizedCaseInsensitiveContains("<vmap") {
            return .vmap
        }
        if sample.localizedCaseInsensitiveContains("<vast") {
            return .vast
        }
        return .unknownXml
    }

    /// Parses a captured XML body into the best available ad summary.
    static func parse(xml: String, kind: AdXmlKind) -> AdXMLParseResult {
        switch kind {
        case .vast:
            return AdXMLParseResult(kind: kind, vast: VASTParser.parse(xml), vmap: nil)
        case .vmap:
            return AdXMLParseResult(kind: kind, vast: nil, vmap: VMAPParser.parse(xml))
        case .unknownXml:
            if let vmap = VMAPParser.parse(xml) {
                return AdXMLParseResult(kind: .vmap, vast: nil, vmap: vmap)
            }
            if let vast = VASTParser.parse(xml) {
                return AdXMLParseResult(kind: .vast, vast: vast, vmap: nil)
            }
            return AdXMLParseResult(kind: kind, vast: nil, vmap: nil)
        }
    }
}

struct AdXMLParseResult: Sendable, Equatable {
    let kind: AdXmlKind
    let vast: VASTSummary?
    let vmap: VMAPSummary?
}
