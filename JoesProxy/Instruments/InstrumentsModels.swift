import Foundation

struct InstrumentsTemplate: Equatable, Sendable, Codable, Identifiable {
    var id: String { name }
    var name: String
    var description: String
}

struct InstrumentsTargetDevice: Equatable, Sendable, Codable, Identifiable {
    var id: String { identifier }
    var name: String
    var identifier: String
    var osVersion: String
    var isSimulator: Bool
}

struct InstrumentsTraceSessionConfig: Equatable, Sendable, Codable {
    var templateName: String
    var targetProcess: String?
    var targetBundleID: String?
    var targetDeviceIdentifier: String?
    var timeLimitSeconds: Int
    var outputTraceURL: URL?

    init(
        templateName: String = "Time Profiler",
        targetProcess: String? = nil,
        targetBundleID: String? = nil,
        targetDeviceIdentifier: String? = nil,
        timeLimitSeconds: Int = 10,
        outputTraceURL: URL? = nil
    ) {
        self.templateName = templateName
        self.targetProcess = targetProcess
        self.targetBundleID = targetBundleID
        self.targetDeviceIdentifier = targetDeviceIdentifier
        self.timeLimitSeconds = max(1, min(timeLimitSeconds, 60))
        self.outputTraceURL = outputTraceURL
    }
}

struct InstrumentsTraceSessionResult: Equatable, Sendable, Codable {
    var traceURL: URL
    var durationSeconds: Double
    var fileSizeBytes: Int
    var exitCode: Int32
}

struct InstrumentsHangEvent: Equatable, Sendable, Codable, Identifiable {
    var id: String { "\(startTimeSeconds)-\(durationMs)" }
    var startTimeSeconds: Double
    var durationMs: Double
    var severity: String
}

struct InstrumentsHotspotFrame: Equatable, Sendable, Codable, Identifiable {
    var id: String { "\(symbol)-\(weightPercentage)" }
    var symbol: String
    var sampleCount: Int
    var weightPercentage: Double
    var binaryName: String
}

struct InstrumentsMetricSummary: Equatable, Sendable, Codable {
    var templateName: String
    var durationSeconds: Double
    var topHotspots: [InstrumentsHotspotFrame]
    var detectedHangs: [InstrumentsHangEvent]
    var totalAllocationsBytes: Int?
    var warnings: [String]
}

struct InstrumentsCausalCorrelationFinding: Equatable, Sendable, Codable, Identifiable {
    var id: String { "\(timestampOffsetSeconds)-\(severity)" }
    var severity: String
    var title: String
    var description: String
    var timestampOffsetSeconds: Double
    var relatedEndpoint: String?
    var relatedPayloadSizeBytes: Int?
    var relatedHangDurationMs: Double?
    var rootCause: String
    var recommendation: String
}

struct InstrumentsCorrelatedAuditReport: Equatable, Sendable, Codable {
    var target: String
    var durationSeconds: Double
    var tracePath: String
    var totalRequestsCaptured: Int
    var totalBytesTransferred: Int
    var mutatedEndpointsCount: Int
    var hostHangsCount: Int
    var peakCPUPercentage: Double?
    var findings: [InstrumentsCausalCorrelationFinding]
    var markdownSummary: String
}
