import Foundation
import SwiftUI

struct SessionFindBodyMatchContext: Equatable, Sendable {
    let query: String
    let matchCount: Int
}

struct SessionFindExcerpt: Equatable {
    let plainText: String
    let attributedText: AttributedString
}

enum SessionFindExcerptResult: Equatable {
    case excerpts([SessionFindExcerpt])
    case tooLarge(actualBytes: Int, limitBytes: Int)
}

struct SessionFindExcerptBuilder: Sendable {
    static let defaultBodySizeLimit = 150 * 1024
    static let defaultContextCharacterCount = 40
    static let defaultMaxExcerptCount = 3

    func build(
        bodyData: Data?,
        query: String,
        maxExcerptCount: Int = Self.defaultMaxExcerptCount,
        contextCharacterCount: Int = Self.defaultContextCharacterCount,
        bodySizeLimit: Int = Self.defaultBodySizeLimit
    ) -> SessionFindExcerptResult? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, maxExcerptCount > 0, contextCharacterCount >= 0 else {
            return nil
        }

        guard let bodyData else {
            return nil
        }

        guard bodyData.count <= bodySizeLimit else {
            return .tooLarge(actualBytes: bodyData.count, limitBytes: bodySizeLimit)
        }

        guard let bodyText = String(data: bodyData, encoding: .utf8), !bodyText.isEmpty else {
            return nil
        }

        var excerpts: [SessionFindExcerpt] = []
        var searchStart = bodyText.startIndex
        let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        while searchStart < bodyText.endIndex,
              excerpts.count < maxExcerptCount,
              let matchRange = bodyText.range(
                of: trimmedQuery,
                options: searchOptions,
                range: searchStart..<bodyText.endIndex
              ) {
            excerpts.append(
                excerpt(
                    in: bodyText,
                    matchRange: matchRange,
                    contextCharacterCount: contextCharacterCount
                )
            )
            searchStart = matchRange.upperBound
        }

        guard !excerpts.isEmpty else {
            return nil
        }

        return .excerpts(excerpts)
    }

    private func excerpt(
        in bodyText: String,
        matchRange: Range<String.Index>,
        contextCharacterCount: Int
    ) -> SessionFindExcerpt {
        let contextStart = bodyText.index(
            matchRange.lowerBound,
            offsetBy: -contextCharacterCount,
            limitedBy: bodyText.startIndex
        ) ?? bodyText.startIndex
        let contextEnd = bodyText.index(
            matchRange.upperBound,
            offsetBy: contextCharacterCount,
            limitedBy: bodyText.endIndex
        ) ?? bodyText.endIndex

        let hasLeadingEllipsis = contextStart > bodyText.startIndex
        let hasTrailingEllipsis = contextEnd < bodyText.endIndex
        var plainText = String(bodyText[contextStart..<contextEnd])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        plainText = plainText.replacingOccurrences(of: "\t", with: " ")

        if hasLeadingEllipsis {
            plainText = "..." + plainText
        }
        if hasTrailingEllipsis {
            plainText += "..."
        }

        let prefixOffset = hasLeadingEllipsis ? 3 : 0
        let lowerOffset = bodyText.distance(from: contextStart, to: matchRange.lowerBound) + prefixOffset
        let upperOffset = bodyText.distance(from: contextStart, to: matchRange.upperBound) + prefixOffset

        var attributedText = AttributedString(plainText)
        let lower = attributedText.index(attributedText.startIndex, offsetByCharacters: lowerOffset)
        let upper = attributedText.index(attributedText.startIndex, offsetByCharacters: upperOffset)
        let attributedRange = lower..<upper
        attributedText[attributedRange].backgroundColor = Color.accentColor.opacity(0.32)
        attributedText[attributedRange].foregroundColor = Color.primary
        attributedText[attributedRange].inlinePresentationIntent = .stronglyEmphasized

        return SessionFindExcerpt(plainText: plainText, attributedText: attributedText)
    }
}
