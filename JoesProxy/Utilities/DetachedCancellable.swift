import Foundation

/// Runs CPU-heavy work off the calling actor while still honoring the calling task's cancellation.
///
/// `Task.detached` creates an unstructured task that never inherits cancellation automatically —
/// without this bridge, cancelling the enclosing task (e.g. a SwiftUI `.task(id:)` instance torn
/// down because its id changed) would silently have no effect on an already-in-flight detached
/// parse: it would keep running to completion regardless, and the caller would keep waiting on it
/// too. `withTaskCancellationHandler` at least makes the *caller* stop waiting as soon as the
/// enclosing task is cancelled, and marks the detached task cancelled so any internal
/// `Task.isCancelled`/`Task.checkCancellation()` check it makes can bail early. It cannot interrupt
/// work already mid-flight inside `work` if `work` never checks cancellation itself.
///
/// Mirrors the identical pattern already used in `MCPMediaInspectionService.runDetachedCancellable`
/// (kept private to that type); shared here so UI-side derivation work (see
/// `JoesProxy/JSONViewer/JSONViewerSheet.swift`) can use the same bridge instead of a bare,
/// uncancellable `Task.detached(...).value`/`.result`.
func runDetachedCancellable<T: Sendable>(
    priority: TaskPriority,
    _ work: @Sendable @escaping () -> T
) async -> T {
    let task = Task.detached(priority: priority, operation: work)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}
