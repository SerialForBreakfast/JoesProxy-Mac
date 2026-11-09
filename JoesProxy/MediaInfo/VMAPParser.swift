//
//  VMAPParser.swift
//  JoesProxy
//
//  Parses captured VMAP XML into a privacy-aware Media Info summary.
//

import Foundation

enum VMAPParser {
    /// Parses VMAP XML text into a structured summary. Returns nil when XML is unreadable.
    static func parse(_ xml: String) -> VMAPSummary? {
        guard let data = xml.data(using: .utf8),
              let document = try? XMLDocument(data: data, options: [.nodePreserveAll, .nodeCompactEmptyElement]),
              let root = document.rootElement() else {
            return nil
        }

        let vmapElement = element(named: "VMAP", in: root) ?? (root.localName == "VMAP" ? root : nil)
        guard let vmapElement else { return nil }

        let version = vmapElement.attribute(forName: "version")?.stringValue
        let adBreaks = elements(named: "AdBreak", in: vmapElement).enumerated().map { index, adBreak in
            parseAdBreak(adBreak, index: index)
        }

        return VMAPSummary(version: version, adBreaks: adBreaks)
    }

    private static func parseAdBreak(_ adBreak: XMLElement, index: Int) -> VMAPAdBreakSummary {
        let timeOffset = adBreak.attribute(forName: "timeOffset")?.stringValue
        let breakID = adBreak.attribute(forName: "breakId")?.stringValue
            ?? adBreak.attribute(forName: "breakID")?.stringValue
        let breakType = adBreak.attribute(forName: "breakType")?.stringValue

        let adSource = element(named: "AdSource", in: adBreak)
        let adTagURI = adSource.flatMap { firstURLText(in: $0, localNames: ["AdTagURI", "VASTAdData"]) }
        let vastAds = adSource.map { elements(named: "VAST", in: $0).count + elements(named: "Ad", in: $0).count } ?? 0

        return VMAPAdBreakSummary(
            id: breakID ?? "break-\(index + 1)",
            timeOffset: timeOffset,
            breakID: breakID,
            breakType: breakType,
            adSourceURI: adTagURI.map { CapturedURLRedaction.displayString(for: $0) },
            vastAdCount: vastAds
        )
    }

    private static func firstURLText(in parent: XMLElement, localNames: [String]) -> String? {
        for name in localNames {
            if let element = element(named: name, in: parent) {
                if name == "VASTAdData" {
                    return "embedded VAST payload"
                }
                if let text = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func element(named name: String, in parent: XMLElement) -> XMLElement? {
        elements(named: name, in: parent).first
    }

    private static func elements(named name: String, in parent: XMLElement) -> [XMLElement] {
        (parent.children ?? []).compactMap { child in
            guard let element = child as? XMLElement else { return nil }
            let localName = element.localName ?? element.name ?? ""
            if localName == name || localName.hasSuffix(":\(name)") {
                return element
            }
            return nil
        }
    }
}
