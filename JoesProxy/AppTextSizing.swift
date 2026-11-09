//
//  AppTextSizing.swift
//  JoesProxy
//
//  Shared app text-size environment and font helpers used across the app.
//

import SwiftUI

enum AppFontRole {
    case caption
    case caption2
    case body
    case subheadline
    case headline
    case title3
    case title2

    var pointSize: CGFloat {
        switch self {
        case .caption:
            return 11
        case .caption2:
            return 10
        case .body:
            return 13
        case .subheadline:
            return 12
        case .headline:
            return 13
        case .title3:
            return 20
        case .title2:
            return 22
        }
    }
}

private struct AppTextScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var appTextScale: CGFloat {
        get { self[AppTextScaleEnvironmentKey.self] }
        set { self[AppTextScaleEnvironmentKey.self] = newValue }
    }
}

extension View {
    func appFont(
        _ role: AppFontRole,
        scale: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        font(.system(size: role.pointSize * scale, weight: weight, design: design))
    }
}

extension AppTextSize {
    var fontScale: CGFloat {
        switch self {
        case .small:
            return 0.92
        case .standard:
            return 1.0
        case .large:
            return 1.12
        case .extraLarge:
            return 1.26
        case .accessibility:
            return 1.42
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small:
            return .small
        case .standard:
            return .large
        case .large:
            return .xLarge
        case .extraLarge:
            return .xxLarge
        case .accessibility:
            return .accessibility1
        }
    }

    var widthMultiplier: CGFloat {
        fontScale
    }
}
