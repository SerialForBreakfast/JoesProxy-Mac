//
//  JSONSyntaxHighlighter.swift
//  JoesProxy
//
//  Tokenizes JSON text for syntax highlighting. Returns an array of `HighlightSpan`
//  values (Sendable) from a background task. The caller applies them to an
//  `NSAttributedString` on the main actor.
//
//  Design notes:
//  - `HighlightSpan` is a fully Sendable value type (NSRange + HighlightColor enum).
//    This avoids transferring AppKit objects across concurrency boundaries.
//  - Tokenization builds no per-token String allocations; it tracks String.Index
//    ranges and converts to NSRange at each token boundary.
//  - `HighlightColor` maps to `NSColor` on the main actor when applying spans.
//

import Foundation

/// A named highlight color, resolved to `NSColor` when applied to an `NSAttributedString`.
///
/// Defined as a value type so spans can be transferred across concurrency boundaries
/// without requiring `NSColor` (an AppKit class) to be `Sendable`.
enum HighlightColor: Sendable {
    case key
    case string
    case number
    case boolean
    case null
    case bracket
    case punctuation
}

/// A single syntax-highlighted range in a JSON string.
struct HighlightSpan: Sendable {
    /// UTF-16 range in the source string, suitable for use with `NSAttributedString`.
    let range: NSRange
    let color: HighlightColor
}

/// Tokenizes JSON and produces `HighlightSpan` values for syntax highlighting.
///
/// Keys are blue, string values green, numbers orange, booleans/brackets purple,
/// null/punctuation secondary label color.
///
/// Call `spans(for:)` from a background task and apply the result on the main actor
/// using `NSAttributedString.applyHighlightSpans(_:)`.
enum JSONSyntaxHighlighter {

    /// Returns an array of `HighlightSpan` values describing how to color `json`.
    ///
    /// Runs a single pass over the input without creating per-token String allocations.
    /// **Call from a background task.** Do not invoke on the main thread for large inputs.
    ///
    /// - Parameter json: Raw JSON string to tokenize.
    /// - Returns: Ordered `HighlightSpan` values covering all colored token ranges.
    static func spans(for json: String) -> [HighlightSpan] {
        let signpost = JSONViewerPerformanceSignposts.beginHighlightTokenize()
        defer { JSONViewerPerformanceSignposts.endHighlightTokenize(signpost) }

        var result: [HighlightSpan] = []
        result.reserveCapacity(json.count / 8)

        var index = json.startIndex
        var currentUTF16Offset = 0

        while index < json.endIndex {
            let char = json[index]
            let next = json.index(after: index)

            if char == "\"" {
                let startOffset = currentUTF16Offset
                let (endIndex, utf16Length) = readStringEnd(json: json, afterOpeningQuote: next)
                let color: HighlightColor = isFollowedByColon(json: json, after: endIndex) ? .key : .string
                result.append(HighlightSpan(range: NSRange(location: startOffset, length: utf16Length), color: color))
                currentUTF16Offset += utf16Length
                index = endIndex
            } else if char.isNumber || (char == "-" && next < json.endIndex && json[next].isNumber) {
                let startOffset = currentUTF16Offset
                let (endIndex, utf16Length) = readNumberEnd(json: json, start: index)
                result.append(HighlightSpan(range: NSRange(location: startOffset, length: utf16Length), color: .number))
                currentUTF16Offset += utf16Length
                index = endIndex
            } else if char == "t", hasKeyword("true", in: json, at: index) {
                let end = json.index(index, offsetBy: 4)
                result.append(HighlightSpan(range: NSRange(location: currentUTF16Offset, length: 4), color: .boolean))
                currentUTF16Offset += 4
                index = end
            } else if char == "f", hasKeyword("false", in: json, at: index) {
                let end = json.index(index, offsetBy: 5)
                result.append(HighlightSpan(range: NSRange(location: currentUTF16Offset, length: 5), color: .boolean))
                currentUTF16Offset += 5
                index = end
            } else if char == "n", hasKeyword("null", in: json, at: index) {
                let end = json.index(index, offsetBy: 4)
                result.append(HighlightSpan(range: NSRange(location: currentUTF16Offset, length: 4), color: .null))
                currentUTF16Offset += 4
                index = end
            } else if char == "{" || char == "}" || char == "[" || char == "]" {
                result.append(HighlightSpan(range: NSRange(location: currentUTF16Offset, length: 1), color: .bracket))
                currentUTF16Offset += 1
                index = next
            } else if char == "," || char == ":" {
                result.append(HighlightSpan(range: NSRange(location: currentUTF16Offset, length: 1), color: .punctuation))
                currentUTF16Offset += 1
                index = next
            } else {
                currentUTF16Offset += char.utf16.count
                index = next
            }
        }

        return result
    }

    // MARK: - Private tokenizer helpers

    /// Returns the index past the closing `"` of a string literal, and the total UTF-16 code units in the token.
    /// `afterOpeningQuote` is the index immediately after the opening `"`.
    private static func readStringEnd(json: String, afterOpeningQuote: String.Index) -> (endIndex: String.Index, utf16Length: Int) {
        var index = afterOpeningQuote
        var utf16Length = 1 // Opening quote
        while index < json.endIndex {
            let char = json[index]
            json.formIndex(after: &index)
            utf16Length += char.utf16.count
            if char == "\\" {
                if index < json.endIndex {
                    utf16Length += json[index].utf16.count
                    json.formIndex(after: &index)
                }
            } else if char == "\"" {
                break
            }
        }
        return (index, utf16Length)
    }

    /// Returns `true` if the first non-whitespace character at or after `start` is `:`.
    private static func isFollowedByColon(json: String, after start: String.Index) -> Bool {
        var index = start
        while index < json.endIndex, json[index].isWhitespace {
            json.formIndex(after: &index)
        }
        return index < json.endIndex && json[index] == ":"
    }

    /// Returns the index past the last character of a number literal starting at `start`, and its UTF-16 code unit count.
    private static func readNumberEnd(json: String, start: String.Index) -> (endIndex: String.Index, utf16Length: Int) {
        var index = start
        var utf16Length = 0
        while index < json.endIndex {
            let char = json[index]
            guard char.isNumber || char == "-" || char == "+" || char == "." || char == "e" || char == "E" else { break }
            utf16Length += char.utf16.count
            json.formIndex(after: &index)
        }
        return (index, utf16Length)
    }

    /// Returns `true` if `json` has `keyword` starting at `index`. No intermediate allocation.
    private static func hasKeyword(_ keyword: String, in json: String, at index: String.Index) -> Bool {
        json[index...].hasPrefix(keyword)
    }
}
