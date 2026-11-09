//
//  WorkspaceCommandAction.swift
//  JoesProxy
//
//  Defines app-level workspace commands so menu items and shortcuts can trigger
//  the same pane and session actions used by the main window UI.
//

import Foundation

enum WorkspaceCommandAction: String {
    case showSessions
    case showBookmarks
    case showLocalOverrides
    case showTable
    case showExplorer
    case showTimeline
    case mapSelectedLocal
    case replaceSelectedWithHLSTestStream
    case newOpenAPIMockPack
    case bookmarkSelectedSession
    case copySelectedAsCurl
    case runSelectedBookmark
    case clearAllSessions
}

extension Notification.Name {
    static let workspaceCommandRequested = Notification.Name("WorkspaceCommandRequested")
}

enum WorkspaceCommandCenter {
    static func post(_ action: WorkspaceCommandAction) {
        NotificationCenter.default.post(
            name: .workspaceCommandRequested,
            object: nil,
            userInfo: ["action": action.rawValue]
        )
    }
}
