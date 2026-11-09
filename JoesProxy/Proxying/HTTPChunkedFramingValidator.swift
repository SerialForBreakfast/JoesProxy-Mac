/// Incremental framing only: no payload, extension or trailer storage. Owned by one event loop.
struct HTTPChunkedFramingValidator {
    private enum State { case size, sizeLF, body, bodyCR, bodyLF, trailer, trailerLF, complete, invalid }
    private var state: State = .size
    private var remaining = 0
    private var hasDigit = false
    private var inExtension = false
    private var sizeWhitespace = false
    private var trailerHasBytes = false
    private var trailerHasColon = false
    var isComplete: Bool { if case .complete = state { return true }; return false }
    var isInvalid: Bool { if case .invalid = state { return true }; return false }

    mutating func consume<C: RandomAccessCollection>(_ bytes: C) where C.Element == UInt8 {
        var index = bytes.startIndex
        while index != bytes.endIndex {
            if case .body = state {
                let count = min(remaining, bytes.distance(from: index, to: bytes.endIndex))
                index = bytes.index(index, offsetBy: count)
                remaining -= count
                if remaining == 0 { state = .bodyCR }
                continue
            }
            let byte = bytes[index]
            index = bytes.index(after: index)
            switch state {
            case .size:
                if byte == 13, hasDigit { state = .sizeLF }
                else if byte == 59, hasDigit { inExtension = true }
                else if (byte == 32 || byte == 9), hasDigit, !inExtension { sizeWhitespace = true }
                else if inExtension {
                    if byte != 9 && (byte < 32 || byte == 127) { state = .invalid }
                } else {
                    if sizeWhitespace { state = .invalid; continue }
                    let digit: Int
                    switch byte {
                    case 48...57: digit = Int(byte - 48)
                    case 65...70: digit = Int(byte - 65 + 10)
                    case 97...102: digit = Int(byte - 97 + 10)
                    default: state = .invalid; continue
                    }
                    let multiplied = remaining.multipliedReportingOverflow(by: 16)
                    let added = multiplied.partialValue.addingReportingOverflow(digit)
                    if multiplied.overflow || added.overflow { state = .invalid }
                    else { remaining = added.partialValue; hasDigit = true }
                }
            case .sizeLF:
                if byte != 10 { state = .invalid }
                else { state = remaining == 0 ? .trailer : .body }
            case .bodyCR: state = byte == 13 ? .bodyLF : .invalid
            case .bodyLF:
                if byte == 10 { state = .size; hasDigit = false; inExtension = false; sizeWhitespace = false }
                else { state = .invalid }
            case .trailer:
                if byte == 13 { state = .trailerLF }
                else if byte == 10 || byte == 127 || (byte < 32 && byte != 9) { state = .invalid }
                else if !trailerHasColon {
                    if byte == 58 && trailerHasBytes { trailerHasColon = true }
                    else if Self.isToken(byte) { trailerHasBytes = true }
                    else { state = .invalid }
                } else { trailerHasBytes = true }
            case .trailerLF:
                if byte != 10 { state = .invalid }
                else if !trailerHasBytes { state = .complete }
                else if !trailerHasColon { state = .invalid }
                else { state = .trailer; trailerHasBytes = false; trailerHasColon = false }
            case .complete: state = .invalid
            case .invalid: return
            case .body: break
            }
        }
    }

    private static func isToken(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 33, 35...39, 42, 43, 45, 46, 94...96, 124, 126: true
        default: false
        }
    }
}
