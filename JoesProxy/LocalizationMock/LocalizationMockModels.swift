//
//  LocalizationMockModels.swift
//  JoesProxy
//
//  Domain models for Localization and Pseudo-Localization Mocking in JoesProxy.
//

import Foundation

/// Supported localization & pseudo-localization transformation presets.
enum LocalizationPresetKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case pseudoAccentedExpansion = "pseudo_expansion"
    case rtlBiDiSimulation = "rtl_bidi"
    case germanCompoundExpansion = "german_compound"
    case cjkDoubleByte = "cjk_double_byte"
    case diacriticStress = "diacritic_stress"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pseudoAccentedExpansion:
            return "Accented Expansion (+40%)"
        case .rtlBiDiSimulation:
            return "RTL BiDi (Arabic/Hebrew)"
        case .germanCompoundExpansion:
            return "Germanic Compound Nouns"
        case .cjkDoubleByte:
            return "CJK Double-Byte"
        case .diacriticStress:
            return "Diacritic & Font Stress"
        }
    }

    var summary: String {
        switch self {
        case .pseudoAccentedExpansion:
            return "Replaces vowels with accented variants and expands string length by ~40% inside [!!! ... !!!] to expose UI label clipping."
        case .rtlBiDiSimulation:
            return "Injects Right-to-Left Unicode marks (U+200F) to test BiDi mirroring and text alignment."
        case .germanCompoundExpansion:
            return "Expands words into long single-token compound nouns to test word wrapping without spaces."
        case .cjkDoubleByte:
            return "Replaces standard Latin characters with full-width CJK Unicode equivalents to test vertical line-height."
        case .diacriticStress:
            return "Applies stacked combining diacritical marks to test custom font baseline and clipping."
        }
    }
}

/// Options controlling the localization transformation process.
struct LocalizationTransformOptions: Codable, Equatable, Sendable {
    var preset: LocalizationPresetKind = .pseudoAccentedExpansion
    var preserveURLs: Bool = true
    var preserveIDs: Bool = true
    var preservePlaceholders: Bool = true
    var customExclusions: [String] = []
}

/// Outcome of a localization transformation pass.
struct LocalizationTransformResult: Codable, Equatable, Sendable {
    var originalData: Data
    var transformedData: Data
    var mutatedStringCount: Int
    var skippedStringCount: Int
    var originalCharacterCount: Int
    var transformedCharacterCount: Int

    var expansionPercentage: Double {
        guard originalCharacterCount > 0 else { return 0.0 }
        let diff = Double(transformedCharacterCount - originalCharacterCount)
        return (diff / Double(originalCharacterCount)) * 100.0
    }

    var transformedString: String {
        String(data: transformedData, encoding: .utf8) ?? ""
    }
}
