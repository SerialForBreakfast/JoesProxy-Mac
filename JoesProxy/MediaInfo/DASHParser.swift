//
//  DASHParser.swift
//  JoesProxy
//
//  Parses DASH MPD manifests for metadata extraction.
//

import Foundation

enum DASHParser {

    /// Parses MPD XML. Returns nil if parsing fails.
    static func parse(_ xmlString: String) -> DASHManifest? {
        guard let data = xmlString.data(using: .utf8) else { return nil }

        let parser = XMLParser(data: data)
        let delegate = MPDDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        return delegate.result
    }
}

private final class MPDDelegate: NSObject, XMLParserDelegate {
    var result: DASHManifest?
    private var periodStart: String?
    private var periodDuration: String?
    private var periodBaseURL: String?
    private var currentRepresentation: DASHRepresentation?
    private var periods: [DASHPeriod] = []
    private var contentProtection: [DASHContentProtection] = []
    private var mpdType: String?
    private var mediaPresentationDuration: String?
    private var mpdBaseURL: String?
    private var adaptationSets: [DASHAdaptationSet] = []
    private var representations: [DASHRepresentation] = []
    private var asID: String?
    private var asContentType: String?
    private var asLang: String?
    private var asMimeType: String?
    private var asCodecs: String?
    private var asBaseURL: String?
    private var asRoles: [DASHDescriptor] = []
    private var asAccessibility: [DASHDescriptor] = []
    private var asAudioChannelConfigurations: [DASHAudioChannelConfiguration] = []
    private var asEventStreams: [DASHEventStream] = []
    private var asSegmentTemplate: DASHSegmentTemplate?
    private var currentElementText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElementText = ""
        switch elementName.lowercased() {
        case "mpd":
            mpdType = attributeDict["type"]
            mediaPresentationDuration = attributeDict["mediaPresentationDuration"]
        case "period":
            periodStart = attributeDict["start"]
            periodDuration = attributeDict["duration"]
            periodBaseURL = nil
        case "adaptationset":
            asID = attributeDict["id"]
            asContentType = attributeDict["contentType"]
            asLang = attributeDict["lang"]
            asMimeType = attributeDict["mimeType"]
            asCodecs = attributeDict["codecs"]
            asBaseURL = nil
            asRoles = []
            asAccessibility = []
            asAudioChannelConfigurations = []
            asEventStreams = []
            asSegmentTemplate = nil
        case "representation":
            currentRepresentation = DASHRepresentation(
                id: attributeDict["id"],
                mimeType: attributeDict["mimeType"],
                codecs: attributeDict["codecs"],
                bandwidth: attributeDict["bandwidth"].flatMap { Int($0) },
                width: attributeDict["width"].flatMap { Int($0) },
                height: attributeDict["height"].flatMap { Int($0) },
                frameRate: attributeDict["frameRate"],
                audioSamplingRate: attributeDict["audioSamplingRate"].flatMap { Int($0) },
                baseURL: nil,
                segmentTemplate: nil
            )
        case "segmenttemplate":
            let template = DASHSegmentTemplate(
                initialization: attributeDict["initialization"],
                media: attributeDict["media"],
                timescale: attributeDict["timescale"].flatMap(Int.init),
                duration: attributeDict["duration"].flatMap(Int.init),
                startNumber: attributeDict["startNumber"].flatMap(Int.init)
            )
            if var currentRepresentation {
                currentRepresentation = DASHRepresentation(
                    id: currentRepresentation.id,
                    mimeType: currentRepresentation.mimeType,
                    codecs: currentRepresentation.codecs,
                    bandwidth: currentRepresentation.bandwidth,
                    width: currentRepresentation.width,
                    height: currentRepresentation.height,
                    frameRate: currentRepresentation.frameRate,
                    audioSamplingRate: currentRepresentation.audioSamplingRate,
                    baseURL: currentRepresentation.baseURL,
                    segmentTemplate: template
                )
                self.currentRepresentation = currentRepresentation
            } else {
                asSegmentTemplate = template
            }
        case "contentprotection":
            if let schemeId = attributeDict["schemeIdUri"] {
                contentProtection.append(DASHContentProtection(
                    schemeIdUri: schemeId,
                    value: attributeDict["value"],
                    defaultKid: attributeDict["cenc:default_KID"] ?? attributeDict["default_KID"],
                    pssh: attributeDict["cenc:pssh"] ?? attributeDict["pssh"]
                ))
            }
        case "role":
            asRoles.append(
                DASHDescriptor(
                    schemeIdUri: attributeDict["schemeIdUri"],
                    value: attributeDict["value"]
                )
            )
        case "accessibility":
            asAccessibility.append(
                DASHDescriptor(
                    schemeIdUri: attributeDict["schemeIdUri"],
                    value: attributeDict["value"]
                )
            )
        case "audiochannelconfiguration":
            asAudioChannelConfigurations.append(
                DASHAudioChannelConfiguration(
                    schemeIdUri: attributeDict["schemeIdUri"],
                    value: attributeDict["value"]
                )
            )
        case "eventstream":
            asEventStreams.append(
                DASHEventStream(
                    schemeIdUri: attributeDict["schemeIdUri"],
                    value: attributeDict["value"],
                    timescale: attributeDict["timescale"].flatMap(Int.init)
                )
            )
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentElementText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName.lowercased() {
        case "baseurl":
            let value = currentElementText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { break }
            if var currentRepresentation {
                currentRepresentation = DASHRepresentation(
                    id: currentRepresentation.id,
                    mimeType: currentRepresentation.mimeType,
                    codecs: currentRepresentation.codecs,
                    bandwidth: currentRepresentation.bandwidth,
                    width: currentRepresentation.width,
                    height: currentRepresentation.height,
                    frameRate: currentRepresentation.frameRate,
                    audioSamplingRate: currentRepresentation.audioSamplingRate,
                    baseURL: value,
                    segmentTemplate: currentRepresentation.segmentTemplate
                )
                self.currentRepresentation = currentRepresentation
            } else if asID != nil || asMimeType != nil || asCodecs != nil || asContentType != nil {
                asBaseURL = value
            } else if periodStart != nil || periodDuration != nil {
                periodBaseURL = value
            } else {
                mpdBaseURL = value
            }
        case "period":
            periods.append(DASHPeriod(
                start: periodStart,
                duration: periodDuration,
                baseURL: periodBaseURL,
                adaptationSets: adaptationSets
            ))
            adaptationSets = []
            periodBaseURL = nil
        case "adaptationset":
            adaptationSets.append(DASHAdaptationSet(
                id: asID,
                contentType: asContentType,
                lang: asLang,
                mimeType: asMimeType,
                codecs: asCodecs,
                baseURL: asBaseURL,
                roles: asRoles,
                accessibility: asAccessibility,
                audioChannelConfigurations: asAudioChannelConfigurations,
                eventStreams: asEventStreams,
                segmentTemplate: asSegmentTemplate,
                representations: representations
            ))
            representations = []
            asID = nil
            asContentType = nil
            asLang = nil
            asBaseURL = nil
            asRoles = []
            asAccessibility = []
            asAudioChannelConfigurations = []
            asEventStreams = []
            asSegmentTemplate = nil
        case "representation":
            if let r = currentRepresentation {
                representations.append(r)
            }
            currentRepresentation = nil
        case "mpd":
            result = DASHManifest(
                type: mpdType,
                mediaPresentationDuration: mediaPresentationDuration,
                baseURL: mpdBaseURL,
                periods: periods,
                contentProtection: contentProtection
            )
        default:
            break
        }
        currentElementText = ""
    }
}
