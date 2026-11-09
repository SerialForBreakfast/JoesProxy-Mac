import XCTest
@testable import JoesProxy

final class InstrumentsTraceParserTests: XCTestCase {

    func testParserExtractsHangsOverThreshold() {
        let sampleXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <trace-export>
            <row>
                <timestamp>1500</timestamp>
                <duration>380</duration>
            </row>
            <row>
                <timestamp>3000</timestamp>
                <duration>45</duration>
            </row>
            <row>
                <timestamp>5200</timestamp>
                <duration>180</duration>
            </row>
        </trace-export>
        """

        let parser = InstrumentsTraceParser()
        let summary = parser.parse(xmlData: Data(sampleXML.utf8), templateName: "Hangs / Hitches")

        // Only hangs >= 100ms should be reported
        XCTAssertEqual(summary.detectedHangs.count, 2)
        XCTAssertEqual(summary.detectedHangs[0].durationMs, 380)
        XCTAssertEqual(summary.detectedHangs[0].severity, "severe")
        XCTAssertEqual(summary.detectedHangs[0].startTimeSeconds, 1.5)

        XCTAssertEqual(summary.detectedHangs[1].durationMs, 180)
        XCTAssertEqual(summary.detectedHangs[1].severity, "moderate")
    }

    func testParserExtractsTopCPUHotspots() {
        let sampleXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <trace-export>
            <row>
                <symbol>JSONDecoder.decode()</symbol>
                <samples>850</samples>
                <binary>Foundation</binary>
            </row>
            <row>
                <symbol>ViewGraph.render()</symbol>
                <samples>320</samples>
                <binary>SwiftUI</binary>
            </row>
            <row>
                <symbol>objc_msgSend</symbol>
                <samples>1200</samples>
                <binary>libobjc.A.dylib</binary>
            </row>
        </trace-export>
        """

        let parser = InstrumentsTraceParser()
        let summary = parser.parse(xmlData: Data(sampleXML.utf8), templateName: "Time Profiler")

        XCTAssertEqual(summary.topHotspots.count, 3)
        // Ordered by sample count descending
        XCTAssertEqual(summary.topHotspots[0].symbol, "objc_msgSend")
        XCTAssertEqual(summary.topHotspots[0].sampleCount, 1200)

        XCTAssertEqual(summary.topHotspots[1].symbol, "JSONDecoder.decode()")
        XCTAssertEqual(summary.topHotspots[1].sampleCount, 850)
    }
}
