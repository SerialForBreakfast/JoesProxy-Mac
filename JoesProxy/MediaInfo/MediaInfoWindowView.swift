//
//  MediaInfoWindowView.swift
//  JoesProxy
//
//  Window routing and tab availability for Media Info.
//

import SwiftUI

struct MediaInfoWindowView: View {
    @EnvironmentObject private var presentationState: AppPresentationState
    @EnvironmentObject private var viewModel: ProxyViewModel
    @EnvironmentObject private var inspectionIndex: MediaInspectionIndex

    var body: some View {
        if let session = selectedSession {
            MediaInfoSheet(session: session, sessions: inspectionIndex.sessions,
                manifestRevision: inspectionIndex.revision, contentRevision: inspectionIndex.selectedRevision,
                manifestModel: inspectionIndex.manifestModel)
                .equatable()
                .onAppear { inspectionIndex.select(session.id) }
                .onChange(of: session.id) { _, id in inspectionIndex.select(id) }
                .safeAreaInset(edge: .bottom) {
                    if inspectionIndex.hasOmittedCandidates || inspectionIndex.browsingOlder {
                        HStack {
                            Text("Related captures are paged; no match in this page is not proof of absence.")
                                .appFont(.caption, scale: viewModel.appTextSize.fontScale)
                            Button("Older Related Captures") { inspectionIndex.showOlder() }
                            Button("Latest") { inspectionIndex.showLatest() }
                        }.padding(8)
                    }
                }
        } else {
            ContentUnavailableView(
                "No Media Session Selected",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Open Media Info from a selected session to inspect captured image, HLS, DASH, or AVAsset details.")
            )
            .frame(minWidth: 760, minHeight: 560)
        }
    }

    private var selectedSession: SessionRecord? {
        guard let sessionID = presentationState.mediaInfoSessionID else {
            return nil
        }

        return viewModel.sessionRecord(for: sessionID)
    }
}
