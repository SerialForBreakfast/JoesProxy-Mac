//
//  WorkspaceProtocols.swift
//  JoesProxy
//
//  Defines the modular workspace architecture: protocol contracts, the Sendable
//  session context snapshot used for off-actor computation, and the AppWorkspace
//  enum that drives center-panel switching in ContentView.
//

import Combine
import Foundation

// MARK: - WorkspaceSessionContext

/// A value-type snapshot of session data captured on the MainActor and safe to
/// ship across actor boundaries without copying locks or references.
///
/// Workspaces capture this snapshot before launching `Task.detached` computation.
/// All fields are `Sendable` value types so the compiler enforces isolation.
struct WorkspaceSessionContext: Sendable {
    let sessions: [SessionRecord]
    let summaries: [SessionRecord.ID: SessionSummary]
}

// MARK: - WorkspaceSortField

/// Sort axes available to workspaces. Aliased as `ProxyViewModel.SessionSortField`.
enum WorkspaceSortField: String, CaseIterable, Identifiable, Sendable, Equatable {
    case startedAt
    case host
    case method
    case statusCode
    case duration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startedAt: return "Time"
        case .host: return "Host"
        case .method: return "Method"
        case .statusCode: return "Status"
        case .duration: return "Duration"
        }
    }
}

// MARK: - WorkspaceViewModelProtocol

/// Read contract every workspace view model exposes to the host (ContentView).
///
/// Conforming types are `@MainActor`-isolated `ObservableObject`s. The protocol
/// surface is intentionally narrow — workspace-specific inputs (filter criteria,
/// grouping, etc.) live on concrete types or on `FilterableWorkspace`.
@MainActor
protocol WorkspaceViewModelProtocol: AnyObject, ObservableObject {
    /// Primary rows the workspace's center panel should render (paginated).
    var displayedSessions: [SessionRecord] { get }
    /// Sessions filtered by pagination but still passing filter criteria.
    var hiddenSessionCount: Int { get }
    /// Sessions excluded by the active filter, not pagination.
    var filteredOutCount: Int { get }
    /// True while a background recompute task is in flight.
    var isRecomputing: Bool { get }
    /// The session currently selected in this workspace.
    var selectedSessionID: SessionRecord.ID? { get set }
    /// Expand the pagination window by one increment.
    func showMoreSessions()
    /// Fast O(1) metadata lookup — returns nil for unknown IDs.
    func summaryLookup(for id: SessionRecord.ID) -> SessionSummary?
}

// MARK: - FilterableWorkspace

/// Extended contract for workspaces that expose filter and search controls.
@MainActor
protocol FilterableWorkspace: WorkspaceViewModelProtocol {
    var filterCriteria: SessionFilterCriteria { get set }
    var searchText: String { get set }
    var sortField: WorkspaceSortField { get set }
    var isSortAscending: Bool { get set }
}

// MARK: - AppWorkspace

/// The available workspace modes. Drives center-panel selection in ContentView.
enum AppWorkspace: String, CaseIterable, Identifiable, Codable, Sendable {
    case capture
    case timeline
    case analytics
    case replay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: return "Capture"
        case .timeline: return "Timeline"
        case .analytics: return "Analytics"
        case .replay: return "Replay"
        }
    }

    var systemImage: String {
        switch self {
        case .capture: return "record.circle"
        case .timeline: return "chart.bar.xaxis"
        case .analytics: return "list.bullet.indent"
        case .replay: return "arrow.clockwise"
        }
    }
}
