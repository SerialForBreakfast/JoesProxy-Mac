import OSLog

/// Instruments signposts for the session Find workflow (panel, search, publish, selection, detail render).
enum SessionFindPerformanceSignposts {
    static let signposter = OSSignposter(
        subsystem: "com.JoesProxyApp.Capture",
        category: "SessionFind"
    )

    static func emitPanelOpen() {
        signposter.emitEvent("SessionFind.panelOpen")
    }

    static func emitSubmit() {
        signposter.emitEvent("SessionFind.submit")
    }

    static func beginSearchTask() -> OSSignpostIntervalState {
        signposter.beginInterval("SessionFind.searchTask")
    }

    static func endSearchTask(_ state: OSSignpostIntervalState) {
        signposter.endInterval("SessionFind.searchTask", state)
    }

    static func beginPublishResults() -> OSSignpostIntervalState {
        signposter.beginInterval("SessionFind.publishResults")
    }

    static func endPublishResults(_ state: OSSignpostIntervalState) {
        signposter.endInterval("SessionFind.publishResults", state)
    }

    static func beginSelectResult() -> OSSignpostIntervalState {
        signposter.beginInterval("SessionFind.selectResult")
    }

    static func endSelectResult(_ state: OSSignpostIntervalState) {
        signposter.endInterval("SessionFind.selectResult", state)
    }

    static func beginDetailRender() -> OSSignpostIntervalState {
        signposter.beginInterval("SessionFind.detailRender")
    }

    static func endDetailRender(_ state: OSSignpostIntervalState) {
        signposter.endInterval("SessionFind.detailRender", state)
    }
}
