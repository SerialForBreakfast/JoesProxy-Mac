import Foundation

struct HLSID3ValidationReport: Equatable, Sendable, Codable {
    var profileID: String
    var carrier: String
    var isValid: Bool
    var scheduledEventsCount: Int
    var parsedMarkersCount: Int
    var warnings: [String]
    var errors: [String]
}

enum HLSID3Validator {
    static func validate(profileDirectory: URL, descriptor: HLSFixtureProfileDescriptor) -> HLSID3ValidationReport {
        guard let schedule = descriptor.id3Schedule else {
            return HLSID3ValidationReport(
                profileID: descriptor.id,
                carrier: "none",
                isValid: true,
                scheduledEventsCount: 0,
                parsedMarkersCount: 0,
                warnings: [],
                errors: []
            )
        }

        var warnings: [String] = []
        var errors: [String] = []
        var totalMarkersFound = 0
        let parser = TimedMetadataID3Parser()

        // Inspect segments in all available variant/rendition directories
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: profileDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return HLSID3ValidationReport(
                profileID: descriptor.id,
                carrier: schedule.carrier,
                isValid: false,
                scheduledEventsCount: schedule.events.count,
                parsedMarkersCount: 0,
                warnings: [],
                errors: ["Unable to read profile directory contents at \(profileDirectory.path)"]
            )
        }

        for item in contents {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                guard let segFiles = try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) else { continue }
                let tsFiles = segFiles.filter { $0.pathExtension.lowercased() == "ts" || $0.pathExtension.lowercased() == "aac" }
                for segURL in tsFiles {
                    if let data = try? Data(contentsOf: segURL) {
                        let result = parser.analyze(
                            data: data,
                            assetID: UUID(),
                            assetURL: segURL,
                            segmentSequence: nil,
                            relativePlaybackTime: nil,
                            shouldCancel: { false }
                        )
                        totalMarkersFound += result.markers.count
                        warnings.append(contentsOf: result.analysisWarnings)

                        // Check frame identifiers against schedule
                        for marker in result.markers {
                            for frame in marker.frameIdentifiers {
                                if !schedule.allowedFrameIDs.contains(frame) {
                                    warnings.append("Found unlisted frame ID \(frame) in \(segURL.lastPathComponent)")
                                }
                            }
                            if schedule.carrier == "packedAudioTimestamp" {
                                if !marker.privateOwnerIdentifiers.contains("com.apple.streaming.transportStreamTimestamp") {
                                    errors.append("Missing required transportStreamTimestamp PRIV frame in \(segURL.lastPathComponent)")
                                }
                            }
                        }
                    }
                }
            }
        }

        let isValid = errors.isEmpty
        return HLSID3ValidationReport(
            profileID: descriptor.id,
            carrier: schedule.carrier,
            isValid: isValid,
            scheduledEventsCount: schedule.events.count,
            parsedMarkersCount: totalMarkersFound,
            warnings: Array(Set(warnings)),
            errors: errors
        )
    }
}
