//
//  MediaInfoViewSupport.swift
//  JoesProxy
//
//  Shared presentation primitives for Media Info views.
//

import SwiftUI

enum MediaInfoFontRole {
    case caption2
    case caption
    case body
    case subheadline
    case headline
    case title3

    var pointSize: CGFloat {
        switch self {
        case .caption2:
            return 11
        case .caption:
            return 12
        case .body:
            return 13
        case .subheadline:
            return 15
        case .headline:
            return 17
        case .title3:
            return 20
        }
    }
}

extension View {
    func mediaInfoFont(
        _ role: MediaInfoFontRole,
        scale: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        font(.system(size: role.pointSize * scale, weight: weight, design: design))
    }
}
