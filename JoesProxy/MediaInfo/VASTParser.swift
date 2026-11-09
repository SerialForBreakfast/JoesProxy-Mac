//
//  VASTParser.swift
//  JoesProxy
//
//  Parses captured VAST XML into a privacy-aware Media Info summary.
//

import Foundation

enum VASTParser {
    /// Parses VAST XML text into a structured summary. Returns nil when XML is unreadable.
    static func parse(_ xml: String) -> VASTSummary? {
        guard let data = xml.data(using: .utf8),
              let document = try? XMLDocument(data: data, options: [.nodePreserveAll, .nodeCompactEmptyElement]),
              let root = document.rootElement() else {
            return nil
        }

        let vastElement = element(named: "VAST", in: root) ?? (root.localName == "VAST" ? root : nil)
        guard let vastElement else { return nil }

        let version = vastElement.attribute(forName: "version")?.stringValue
        var impressionCount = 0
        var clickCount = 0
        var maxDepth = 0

        let ads = elements(named: "Ad", in: vastElement).enumerated().compactMap { index, adElement -> VASTAdSummary? in
            parseAd(
                adElement,
                index: index,
                wrapperDepth: 0,
                maxWrapperDepth: &maxDepth,
                impressionCount: &impressionCount,
                clickCount: &clickCount
            )
        }

        return VASTSummary(
            version: version,
            ads: ads,
            impressionURLCount: impressionCount,
            clickTrackingURLCount: clickCount,
            maxWrapperDepth: maxDepth
        )
    }

    private static func parseAd(
        _ adElement: XMLElement,
        index: Int,
        wrapperDepth: Int,
        maxWrapperDepth: inout Int,
        impressionCount: inout Int,
        clickCount: inout Int
    ) -> VASTAdSummary? {
        maxWrapperDepth = max(maxWrapperDepth, wrapperDepth)

        let adID = adElement.attribute(forName: "id")?.stringValue
        let inlineElement = element(named: "InLine", in: adElement)
        let wrapperElement = element(named: "Wrapper", in: adElement)

        if let inlineElement {
            impressionCount += urlElements(named: "Impression", in: inlineElement).count
            clickCount += urlElements(named: "ClickTracking", in: inlineElement).count
            let creatives = parseCreatives(in: inlineElement, adID: adID)
            return VASTAdSummary(
                id: adID ?? "ad-\(index + 1)",
                kind: .inline,
                wrapperURLRedacted: nil,
                creatives: creatives
            )
        }

        if let wrapperElement {
            impressionCount += urlElements(named: "Impression", in: wrapperElement).count
            clickCount += urlElements(named: "ClickTracking", in: wrapperElement).count
            maxWrapperDepth = max(maxWrapperDepth, wrapperDepth + 1)
            let wrapperURL = firstURLText(in: wrapperElement, localNames: ["VASTAdTagURI", "VASTAdTagURL"])
            let creatives = parseCreatives(in: wrapperElement, adID: adID)

            return VASTAdSummary(
                id: adID ?? "wrapper-\(index + 1)",
                kind: .wrapper,
                wrapperURLRedacted: wrapperURL.map { CapturedURLRedaction.displayString(for: $0) },
                creatives: creatives
            )
        }

        return nil
    }

    private static func parseCreatives(in parent: XMLElement, adID: String?) -> [VASTCreativeSummary] {
        let creativeParent = element(named: "Creatives", in: parent) ?? parent
        return elements(named: "Creative", in: creativeParent).enumerated().map { index, creativeElement in
            let creativeAdID = creativeElement.attribute(forName: "AdID")?.stringValue ?? adID
            let sequence = creativeElement.attribute(forName: "sequence").flatMap { Int($0.stringValue ?? "") }
            let linear = element(named: "Linear", in: creativeElement)
            let durationSeconds = linear.flatMap { parseDuration(element(named: "Duration", in: $0)?.stringValue) }
            let mediaFiles = linear.map { parseMediaFiles(in: $0) } ?? []
            let companionParent = element(named: "CompanionAds", in: creativeElement) ?? creativeElement
            let companionElements = elements(named: "Companion", in: companionParent)
            let companions = companionElements.enumerated().map { compIndex, compElement in
                parseCompanion(compElement, index: compIndex)
            }

            return VASTCreativeSummary(
                id: creativeAdID ?? "creative-\(index + 1)",
                adID: creativeAdID,
                sequence: sequence,
                durationSeconds: durationSeconds,
                mediaFiles: mediaFiles,
                companionCount: companions.count,
                companions: companions
            )
        }
    }

    private static func parseCompanion(_ element: XMLElement, index: Int) -> VASTCompanionAd {
        let id = element.attribute(forName: "id")?.stringValue ?? "companion-\(index + 1)"
        let width = element.attribute(forName: "width").flatMap { Int($0.stringValue ?? "") }
        let height = element.attribute(forName: "height").flatMap { Int($0.stringValue ?? "") }
        let assetWidth = element.attribute(forName: "assetWidth").flatMap { Int($0.stringValue ?? "") }
        let assetHeight = element.attribute(forName: "assetHeight").flatMap { Int($0.stringValue ?? "") }

        var resource: VASTCompanionResource?
        if let staticElem = self.element(named: "StaticResource", in: element) {
            let mimeType = staticElem.attribute(forName: "creativeType")?.stringValue ?? "image/jpeg"
            let urlText = staticElem.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let redacted = CapturedURLRedaction.displayString(for: urlText)
            resource = .staticResource(mimeType: mimeType, url: redacted)
        } else if let iframeElem = self.element(named: "IFrameResource", in: element) {
            let urlText = iframeElem.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let redacted = CapturedURLRedaction.displayString(for: urlText)
            resource = .iFrameResource(url: redacted)
        } else if let htmlElem = self.element(named: "HTMLResource", in: element) {
            let content = htmlElem.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            resource = .htmlResource(content: content)
        }

        let clickThroughURL = firstURLText(in: element, localNames: ["CompanionClickThrough"]).map {
            CapturedURLRedaction.displayString(for: $0)
        }

        let clickTrackers = urlElements(named: "CompanionClickTracking", in: element).compactMap {
            $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.map { CapturedURLRedaction.displayString(for: $0) }

        let altText = self.element(named: "AltText", in: element)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        return VASTCompanionAd(
            id: id,
            width: width,
            height: height,
            assetWidth: assetWidth,
            assetHeight: assetHeight,
            resource: resource,
            clickThroughURL: clickThroughURL,
            clickTrackers: clickTrackers,
            altText: altText
        )
    }

    private static func parseMediaFiles(in linear: XMLElement) -> [VASTMediaFileSummary] {
        guard let mediaFiles = element(named: "MediaFiles", in: linear) else { return [] }

        return elements(named: "MediaFile", in: mediaFiles).enumerated().map { index, mediaFile in
            let urlText = mediaFile.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlRedacted: String?
            if let urlText, !urlText.isEmpty {
                urlRedacted = CapturedURLRedaction.displayString(for: urlText)
            } else {
                urlRedacted = nil
            }

            return VASTMediaFileSummary(
                id: "media-\(index + 1)",
                delivery: mediaFile.attribute(forName: "delivery")?.stringValue,
                mimeType: mediaFile.attribute(forName: "type")?.stringValue,
                width: mediaFile.attribute(forName: "width").flatMap { Int($0.stringValue ?? "") },
                height: mediaFile.attribute(forName: "height").flatMap { Int($0.stringValue ?? "") },
                urlRedacted: urlRedacted
            )
        }
    }

    private static func parseDuration(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func firstURLText(in parent: XMLElement, localNames: [String]) -> String? {
        for name in localNames {
            if let element = element(named: name, in: parent),
               let text = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func urlElements(named name: String, in parent: XMLElement) -> [XMLElement] {
        elements(named: name, in: parent).filter { element in
            guard let text = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !text.isEmpty
        }
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
