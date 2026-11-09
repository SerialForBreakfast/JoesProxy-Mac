import Foundation

/// Bounds presentation work only. Capture storage and explicit full-body copy remain unchanged.
struct InspectorBodyPage {
    static let byteLimit = 12 * 1024

    let text: String
    let byteRange: Range<Int>
    let pageIndex: Int
    let pageCount: Int
    let totalBytes: Int
    let isBase64: Bool

    init(data: Data, page: Int, binary: Bool) {
        totalBytes = data.count
        let nominalCount = max(1, data.count / Self.byteLimit + (data.count % Self.byteLimit == 0 ? 0 : 1))
        let trailingScalarOnly = !binary && nominalCount > 1 &&
            Self.scalarBoundary((nominalCount - 1) * Self.byteLimit, in: data) == data.count
        pageCount = trailingScalarOnly ? nominalCount - 1 : nominalCount
        pageIndex = min(max(0, page), pageCount - 1)
        var start = pageIndex * Self.byteLimit
        var end = min(start + Self.byteLimit, data.count)
        // Assign a UTF-8 scalar crossing a page boundary to the preceding page.
        // At most three continuation bytes are visited at either boundary.
        if !binary {
            start = Self.scalarBoundary(start, in: data)
            end = Self.scalarBoundary(end, in: data)
        }
        byteRange = start..<max(start, end)
        let bytes = data.subdata(in: (data.startIndex + start)..<(data.startIndex + max(start, end)))
        if !binary, let decoded = String(data: bytes, encoding: .utf8) {
            text = decoded
            isBase64 = false
        } else {
            text = bytes.base64EncodedString()
            isBase64 = true
        }
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    private static func scalarBoundary(_ offset: Int, in data: Data) -> Int {
        guard offset > 0, offset < data.count,
              isContinuation(data[data.startIndex + offset]) else { return offset }
        var lead = offset
        for _ in 0..<3 where lead > 0 && isContinuation(data[data.startIndex + lead]) {
            lead -= 1
        }
        let byte = data[data.startIndex + lead]
        let length = byte >= 0xF0 && byte <= 0xF4 ? 4 :
            (byte >= 0xE0 && byte <= 0xEF ? 3 : (byte >= 0xC2 && byte <= 0xDF ? 2 : 0))
        let end = lead + length
        guard end > offset, end <= data.count,
              String(data: data.subdata(in: (data.startIndex + lead)..<(data.startIndex + end)),
                     encoding: .utf8) != nil else { return offset }
        return end
    }
}
