//
//  StatefulMockCoordinator.swift
//  JoesProxy
//
//  Composition root and observable coordinator for virtual stateful backends.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class StatefulMockCoordinator: ObservableObject {

    @Published private(set) var backends: [StatefulVirtualBackend] = []
    @Published private(set) var selectedBackend: StatefulVirtualBackend?

    let store: StatefulMockStore

    init(store: StatefulMockStore = StatefulMockStore()) {
        self.store = store
        Task {
            await self.refresh()
        }
    }

    func refresh() async {
        let all = await store.allBackends()
        self.backends = all
        if selectedBackend == nil || !all.contains(where: { $0.id == selectedBackend?.id }) {
            self.selectedBackend = all.first
        } else if let sel = selectedBackend, let updated = all.first(where: { $0.id == sel.id }) {
            self.selectedBackend = updated
        }
    }

    func selectBackend(_ backend: StatefulVirtualBackend) {
        self.selectedBackend = backend
    }

    func installPreset(_ preset: StatefulMockPreset, customHost: String? = nil) async {
        let host = customHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? customHost! : preset.defaultHost
        let backend = preset.backendFactory(host)
        await store.registerBackend(backend, initialEntities: preset.initialEntities)
        await refresh()
    }

    func setState(backendID: StatefulBackendID, state: String) async {
        await store.setState(backendID: backendID, state: state)
        await refresh()
    }

    func resetBackend(id: StatefulBackendID) async {
        await store.resetBackend(id: id)
        await refresh()
    }

    func removeBackend(id: StatefulBackendID) async {
        await store.removeBackend(id: id)
        await refresh()
    }
}
