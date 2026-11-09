//
//  LocalizationMockEngine.swift
//  JoesProxy
//
//  Deterministic recursive JSON transformer applying pseudo-localization and language mocking.
//

import Foundation

enum LocalizationMockEngine {

    /// Transforms a JSON response body according to localization options.
    static func transform(
        jsonData: Data,
        options: LocalizationTransformOptions = LocalizationTransformOptions()
    ) -> LocalizationTransformResult {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed]) else {
            return LocalizationTransformResult(
                originalData: jsonData,
                transformedData: jsonData,
                mutatedStringCount: 0,
                skippedStringCount: 0,
                originalCharacterCount: 0,
                transformedCharacterCount: 0
            )
        }

        var mutatedCount = 0
        var skippedCount = 0
        var origCharCount = 0
        var transCharCount = 0

        let mutatedObject = mutateValue(
            jsonObject,
            keyContext: nil,
            options: options,
            mutatedCount: &mutatedCount,
            skippedCount: &skippedCount,
            origCharCount: &origCharCount,
            transCharCount: &transCharCount
        )

        let transformedData: Data
        if let data = try? JSONSerialization.data(withJSONObject: mutatedObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
            transformedData = data
        } else {
            transformedData = jsonData
        }

        return LocalizationTransformResult(
            originalData: jsonData,
            transformedData: transformedData,
            mutatedStringCount: mutatedCount,
            skippedStringCount: skippedCount,
            originalCharacterCount: origCharCount,
            transformedCharacterCount: transCharCount
        )
    }

    // MARK: - Recursive Traversal

    private static func mutateValue(
        _ value: Any,
        keyContext: String?,
        options: LocalizationTransformOptions,
        mutatedCount: inout Int,
        skippedCount: inout Int,
        origCharCount: inout Int,
        transCharCount: inout Int
    ) -> Any {
        if let dict = value as? [String: Any] {
            var mutatedDict: [String: Any] = [:]
            for (k, v) in dict {
                mutatedDict[k] = mutateValue(
                    v,
                    keyContext: k,
                    options: options,
                    mutatedCount: &mutatedCount,
                    skippedCount: &skippedCount,
                    origCharCount: &origCharCount,
                    transCharCount: &transCharCount
                )
            }
            return mutatedDict
        } else if let array = value as? [Any] {
            return array.map {
                mutateValue(
                    $0,
                    keyContext: keyContext,
                    options: options,
                    mutatedCount: &mutatedCount,
                    skippedCount: &skippedCount,
                    origCharCount: &origCharCount,
                    transCharCount: &transCharCount
                )
            }
        } else if let str = value as? String {
            origCharCount += str.count
            if shouldSkipString(str, keyContext: keyContext, options: options) {
                skippedCount += 1
                transCharCount += str.count
                return str
            } else {
                mutatedCount += 1
                let transformed = transformString(str, preset: options.preset)
                transCharCount += transformed.count
                return transformed
            }
        }

        return value
    }

    // MARK: - Skip Logic & Guardrails

    private static func shouldSkipString(
        _ str: String,
        keyContext: String?,
        options: LocalizationTransformOptions
    ) -> Bool {
        if str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        // 1. URL Protection
        if options.preserveURLs && (str.hasPrefix("http://") || str.hasPrefix("https://") || str.hasPrefix("ftp://")) {
            return true
        }

        // 2. ID / Token / Key context protection
        if let key = keyContext?.lowercased() {
            if options.customExclusions.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                return true
            }
            if options.preserveIDs {
                let idKeys = ["id", "_id", "uuid", "token", "auth", "hash", "key", "url", "uri", "href", "date", "timestamp", "version", "schema"]
                if idKeys.contains(key) || key.hasSuffix("_id") || key.hasSuffix("id") {
                    return true
                }
            }
        }

        // 3. UUID String Protection
        if options.preserveIDs && isUUID(str) {
            return true
        }

        // 4. ISO8601 Timestamp Protection
        if isISO8601Date(str) {
            return true
        }

        return false
    }

    private static func isUUID(_ str: String) -> Bool {
        guard str.count == 36 else { return false }
        return UUID(uuidString: str) != nil
    }

    private static func isISO8601Date(_ str: String) -> Bool {
        guard str.count >= 19 else { return false }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: str) != nil
    }

    // MARK: - Transformation Algorithms

    static func transformString(_ input: String, preset: LocalizationPresetKind) -> String {
        switch preset {
        case .pseudoAccentedExpansion:
            return pseudoAccentedExpand(input)
        case .rtlBiDiSimulation:
            return rtlBiDiSimulate(input)
        case .germanCompoundExpansion:
            return germanCompoundExpand(input)
        case .cjkDoubleByte:
            return cjkDoubleByteConvert(input)
        case .diacriticStress:
            return diacriticStressApply(input)
        }
    }

    private static func pseudoAccentedExpand(_ input: String) -> String {
        let accentMap: [Character: Character] = [
            "a": "å", "A": "Å",
            "b": "ƀ", "B": "Ɓ",
            "c": "ç", "C": "Ç",
            "d": "ð", "D": "Ð",
            "e": "é", "E": "É",
            "f": "ƒ", "F": "Ƒ",
            "g": "ĝ", "G": "Ĝ",
            "h": "ĥ", "H": "Ĥ",
            "i": "î", "I": "Î",
            "j": "ĵ", "J": "Ĵ",
            "k": "ƙ", "K": "Ƙ",
            "l": "ļ", "L": "Ļ",
            "m": "ɱ", "M": "Ṁ",
            "n": "ñ", "N": "Ñ",
            "o": "ô", "O": "Ô",
            "p": "þ", "P": "Þ",
            "q": "ʠ", "Q": "Ǫ",
            "r": "ř", "R": "Ř",
            "s": "š", "S": "Š",
            "t": "ť", "T": "Ť",
            "u": "û", "U": "Û",
            "v": "ṽ", "V": "Ṽ",
            "w": "ŵ", "W": "Ŵ",
            "x": "ẋ", "X": "Ẋ",
            "y": "ŷ", "Y": "Ŷ",
            "z": "ž", "Z": "Ž"
        ]

        var accented = String(input.map { accentMap[$0] ?? $0 })

        // Expand length by ~40% with repeating tail characters
        let extraCharsCount = max(3, Int(Double(input.count) * 0.4))
        let padding = String(repeating: "~", count: extraCharsCount)

        return "[!!! \(accented) \(padding) !!!]"
    }

    private static func rtlBiDiSimulate(_ input: String) -> String {
        let rtlMark = "\u{200F}" // Right-to-Left Mark
        let words = input.split(separator: " ")
        let reversedWords = words.reversed().joined(separator: " ")
        return "\(rtlMark)[\(reversedWords)]\(rtlMark)"
    }

    private static func germanCompoundExpand(_ input: String) -> String {
        let words = input.split(separator: " ").map(String.init)
        if words.isEmpty { return input }

        let compounded = words.joined(separator: "übertragungs")
        return "\(compounded)verwaltungsanzeige"
    }

    private static func cjkDoubleByteConvert(_ input: String) -> String {
        // Convert ASCII (0x21 to 0x7E) to Fullwidth (0xFF01 to 0xFF5E)
        var result = ""
        for scalar in input.unicodeScalars {
            if scalar.value >= 0x21 && scalar.value <= 0x7E {
                if let fullwidth = UnicodeScalar(scalar.value + 0xFEE0) {
                    result.append(Character(fullwidth))
                    continue
                }
            }
            result.append(Character(scalar))
        }
        return "【\(result)】"
    }

    private static func diacriticStressApply(_ input: String) -> String {
        let combiningDiacritics: [Character] = ["\u{0300}", "\u{0301}", "\u{0302}", "\u{0303}", "\u{0308}"]
        var result = ""
        for (index, char) in input.enumerated() {
            result.append(char)
            if char.isLetter {
                let diacritic = combiningDiacritics[index % combiningDiacritics.count]
                result.append(diacritic)
            }
        }
        return result
    }
}
