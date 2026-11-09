import Foundation

final class InstrumentsTraceParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var currentElement: String = ""
    private var currentCharacters: String = ""
    private var currentRow: [String: String] = [:]

    private var hotspots: [InstrumentsHotspotFrame] = []
    private var hangs: [InstrumentsHangEvent] = []
    private var totalAllocationBytes: Int = 0
    private var warnings: [String] = []

    func parse(xmlData: Data, templateName: String = "Time Profiler") -> InstrumentsMetricSummary {
        let parser = XMLParser(data: xmlData)
        parser.delegate = self
        parser.parse()

        let sortedHotspots = hotspots.sorted { $0.sampleCount > $1.sampleCount }
        let top5 = Array(sortedHotspots.prefix(5))

        return InstrumentsMetricSummary(
            templateName: templateName,
            durationSeconds: 10.0,
            topHotspots: top5,
            detectedHangs: hangs,
            totalAllocationsBytes: totalAllocationBytes > 0 ? totalAllocationBytes : nil,
            warnings: warnings
        )
    }

    func parse(fileURL: URL, templateName: String = "Time Profiler") -> InstrumentsMetricSummary {
        guard let data = try? Data(contentsOf: fileURL) else {
            return InstrumentsMetricSummary(
                templateName: templateName,
                durationSeconds: 0,
                topHotspots: [],
                detectedHangs: [],
                totalAllocationsBytes: nil,
                warnings: ["Failed to read trace XML at \(fileURL.path)"]
            )
        }
        return parse(xmlData: data, templateName: templateName)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentCharacters = ""
        if elementName == "row" {
            currentRow = [:]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentCharacters.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentCharacters.trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty {
            currentRow[elementName] = text
        }

        if elementName == "row" {
            processRow(currentRow)
        }
    }

    private func processRow(_ row: [String: String]) {
        // Time Profiler / Call Tree row detection
        if let symbol = row["symbol"] ?? row["name"] ?? row["frame"],
           let weightStr = row["weight"] ?? row["count"] ?? row["samples"] {
            let samples = Int(weightStr) ?? 1
            let binary = row["binary"] ?? row["module"] ?? "App"
            hotspots.append(InstrumentsHotspotFrame(
                symbol: symbol,
                sampleCount: samples,
                weightPercentage: Double(samples),
                binaryName: binary
            ))
        }

        // Hang / Hitch row detection
        if let durationStr = row["duration"] ?? row["hang-duration"] ?? row["duration-ms"] {
            let duration = Double(durationStr) ?? 0
            if duration >= 100.0 { // Minimum 100ms for user-perceivable hang
                let startStr = row["start"] ?? row["timestamp"] ?? "0"
                let start = (Double(startStr) ?? 0) / 1000.0 // Normalize to seconds
                let severity = duration >= 250.0 ? "severe" : "moderate"
                hangs.append(InstrumentsHangEvent(
                    startTimeSeconds: start,
                    durationMs: duration,
                    severity: severity
                ))
            }
        }

        // Allocations row detection
        if let bytesStr = row["bytes"] ?? row["size"] ?? row["allocations"] {
            if let bytes = Int(bytesStr) {
                totalAllocationBytes += bytes
            }
        }
    }
}
