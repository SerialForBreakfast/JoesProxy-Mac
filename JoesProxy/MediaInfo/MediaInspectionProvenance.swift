//
//  MediaInspectionProvenance.swift
//  JoesProxy
//
//  Labels whether Media Info data comes from captured bytes or live system probes.
//

import Foundation

enum MediaInspectionProvenance: String, Sendable {
    case capturedResponse
    case liveSystemProbe

    var title: String {
        switch self {
        case .capturedResponse:
            return "Captured Response"
        case .liveSystemProbe:
            return "Live System Probe"
        }
    }

    var summary: String {
        switch self {
        case .capturedResponse:
            return "Derived from captured response bytes already stored in JoesProxy."
        case .liveSystemProbe:
            return "Loaded live through system media frameworks and may differ from the captured response."
        }
    }
}
