//
//  StatefulMockEntityBrowserView.swift
//  JoesProxy
//
//  Live in-memory database table inspector for collections and entities.
//

import SwiftUI

struct StatefulMockEntityBrowserView: View {
    let backendID: StatefulBackendID
    let store: StatefulMockStore

    @State private var collections: [String: [StatefulMockEntity]] = [:]
    @State private var selectedCollection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("In-Memory Collections", systemImage: "cylinder.split.1x2")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: {
                    Task { await loadData() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            if collections.isEmpty {
                Text("No collections or entities currently stored.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Collection Picker Tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(collections.keys).sorted(), id: \.self) { col in
                            Button(action: {
                                selectedCollection = col
                            }) {
                                Text("\(col) (\(collections[col]?.count ?? 0))")
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(selectedCollection == col ? Color.accentColor : Color.primary.opacity(0.06))
                                    .foregroundColor(selectedCollection == col ? .white : .primary)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Entity Table
                if let current = selectedCollection, let items = collections[current], !items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Text(item.id)
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .frame(width: 80, alignment: .leading)

                                Text(item.fields.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .foregroundColor(.secondary)

                                Spacer()

                                Button(action: {
                                    Task {
                                        await store.deleteEntity(backendID: backendID, collection: current, id: item.id)
                                        await loadData()
                                    }
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red.opacity(0.7))
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.02))
                            .cornerRadius(6)
                        }
                    }
                } else {
                    Text("Selected collection is empty.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
        .task {
            await loadData()
        }
    }

    private func loadData() async {
        let cols = await store.allCollections(backendID: backendID)
        self.collections = cols
        if selectedCollection == nil || !cols.keys.contains(selectedCollection ?? "") {
            self.selectedCollection = cols.keys.sorted().first
        }
    }
}
