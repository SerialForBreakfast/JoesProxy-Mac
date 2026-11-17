import SwiftUI

/// A separate configuration window. Its drafts and editors do not belong to either workspace mode.
struct TrafficModificationsWindowView: View {
    static let windowID = "traffic-modifications"
    @EnvironmentObject private var viewModel: ProxyViewModel
    @EnvironmentObject private var presentationState: AppPresentationState
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var mapLocalSheetContext: MapLocalSheetContext?
    @State private var hlsTestStreamSheetContext: HLSTestStreamSheetContext?
    @State private var openAPIMockPackSheetContext: OpenAPIMockPackSheetContext?
    @State private var responseOverrideEditorContext: ResponseOverrideEditorContext?
    @State private var inspectedSession: SessionRecord?

    var body: some View {
        ResponseOverridesSheet(
            viewModel: viewModel,
            onEditRule: { responseOverrideEditorContext = ResponseOverrideEditorContext(rule: $0) },
            onNewHLSTestStream: {
                hlsTestStreamSheetContext = HLSTestStreamSheetContext(session: viewModel.selectedSession)
            },
            onNewOpenAPIMockPack: {
                openAPIMockPackSheetContext = OpenAPIMockPackSheetContext(session: viewModel.selectedSession)
            },
            onInspectRecoveryRequest: { id in
                guard let session = viewModel.sessionRecord(for: id) else {
                    return "The captured request is no longer available. Existing receipt details are preserved."
                }
                inspectedSession = session
                return nil
            },
            isPresented: Binding(get: { true }, set: { presented in
                if !presented { dismissWindow(id: Self.windowID) }
            }),
            authoringDraft: presentationState.capturedMockAuthoringDraft,
            discardAuthoringDraft: { await presentationState.discardCapturedMockAuthoringDraft() }
        )
        .environment(\.appTextScale, viewModel.appTextSize.fontScale)
        .background(UITestPrimaryScreenWindowConfigurator().frame(width: 0, height: 0))
        .task(id: presentationState.trafficModificationEditor) {
            switch presentationState.trafficModificationEditor {
            case .openAPI:
                openAPIMockPackSheetContext = OpenAPIMockPackSheetContext(session: viewModel.selectedSession)
            case .testStream:
                hlsTestStreamSheetContext = HLSTestStreamSheetContext(session: viewModel.selectedSession)
            case nil:
                return
            }
            presentationState.trafficModificationEditor = nil
        }
            .sheet(item: $mapLocalSheetContext) { context in
                MapLocalSheet(
                    session: context.session,
                    existingOverrides: viewModel.responseOverrides,
                    onCreateCapturedResponse: { label, matchMode, matchPath, conflictStrategy, forceNoCache in
                        Task {
                            await viewModel.createCapturedResponseOverride(
                                from: context.session,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                conflictStrategy: conflictStrategy,
                                forceNoCache: forceNoCache
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateInlineOverride: { label, matchMode, matchPath, conflictStrategy, statusCode, contentType, bodyText, forceNoCache in
                        Task {
                            await viewModel.createInlineResponseOverride(
                                from: context.session,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                conflictStrategy: conflictStrategy,
                                statusCode: statusCode,
                                contentType: contentType,
                                bodyText: bodyText,
                                forceNoCache: forceNoCache
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateFileBackedOverride: { label, matchMode, matchPath, conflictStrategy, statusCode, contentType, fileURL, forceNoCache in
                        Task {
                            await viewModel.createFileBackedResponseOverride(
                                from: context.session,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                conflictStrategy: conflictStrategy,
                                statusCode: statusCode,
                                contentType: contentType,
                                fileURL: fileURL,
                                forceNoCache: forceNoCache
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateDirectoryBackedOverride: { label, matchPath, conflictStrategy, directoryURL, forceNoCache in
                        Task {
                            await viewModel.createDirectoryBackedResponseOverride(
                                from: context.session,
                                label: label,
                                matchPath: matchPath,
                                conflictStrategy: conflictStrategy,
                                directoryURL: directoryURL,
                                forceNoCache: forceNoCache
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateBlockRule: { label, matchMode, matchPath, statusCode in
                        Task {
                            await viewModel.createBlockRule(
                                from: context.session,
                                statusCode: statusCode,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateMapRemoteRule: { label, matchMode, matchPath, remoteHost, remotePort, remoteScheme, remotePath, allowLoopbackDestination, preserveHostHeader in
                        Task {
                            await viewModel.createMapRemoteRule(
                                from: context.session,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                remoteHost: remoteHost,
                                remotePort: remotePort,
                                remoteScheme: remoteScheme,
                                remotePath: remotePath,
                                allowLoopbackDestination: allowLoopbackDestination,
                                preserveHostHeader: preserveHostHeader
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onCreateLiveResponseRewrite: { label, matchMode, matchPath, jsonPath, operation, value in
                        Task {
                            await viewModel.createLiveResponseRewriteRule(
                                from: context.session,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                jsonPath: jsonPath,
                                operation: operation,
                                overrideValue: value
                            )
                        }
                        mapLocalSheetContext = nil
                    },
                    onOpenHLSTestStream: {
                        mapLocalSheetContext = nil
                        hlsTestStreamSheetContext = HLSTestStreamSheetContext(session: context.session)
                    },
                    onCancel: {
                        mapLocalSheetContext = nil
                    }
                )
            }
            .sheet(item: $hlsTestStreamSheetContext) { context in
                HLSTestStreamSheet(
                    session: context.session,
                    profiles: viewModel.hlsFixtureProfiles,
                    loadConflictSummary: { origin, scope in
                        await viewModel.hlsTestStreamConflictSummary(origin: origin, scope: scope)
                    },
                    onStart: { profileID, origin, scope, conflictStrategy in
                        Task {
                            await viewModel.startHLSTestStream(
                                profileID: profileID,
                                origin: origin,
                                scope: scope,
                                conflictStrategy: conflictStrategy
                            )
                        }
                        hlsTestStreamSheetContext = nil
                    },
                    onCancel: {
                        hlsTestStreamSheetContext = nil
                    }
                )
            }
            .sheet(item: $openAPIMockPackSheetContext) { context in
                OpenAPIMockPackSheet(
                    session: context.session,
                    compilePreview: { bookmark, origin in
                        try viewModel.compileOpenAPIMockPack(bookmark: bookmark, origin: origin)
                    },
                    previewActivation: { compiled, strategy in
                        await viewModel.previewOpenAPIMockActivation(
                            compiled: compiled,
                            conflictStrategy: strategy
                        )
                    },
                    onActivate: { compiled, bookmark, origin, strategy, addWithoutStarting in
                        Task {
                            await viewModel.submitOpenAPIMockPack(
                                compiled: compiled,
                                bookmark: bookmark,
                                origin: origin,
                                conflictStrategy: strategy,
                                addWithoutStarting: addWithoutStarting
                            )
                        }
                        openAPIMockPackSheetContext = nil
                    },
                    onCancel: {
                        openAPIMockPackSheetContext = nil
                    }
                )
            }
            .sheet(item: $responseOverrideEditorContext) { context in
                ResponseOverrideEditorSheet(
                    rule: context.rule,
                    onSaveCaptured: { label, matchMode, matchPath, statusCode, contentType, forceNoCache in
                        Task {
                            await viewModel.updateCapturedResponseOverride(
                                id: context.rule.id,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                statusCode: statusCode,
                                contentType: contentType,
                                forceNoCache: forceNoCache
                            )
                        }
                        responseOverrideEditorContext = nil
                    },
                    onSaveInline: { label, matchMode, matchPath, statusCode, contentType, bodyText, forceNoCache in
                        Task {
                            await viewModel.updateInlineTextResponseOverride(
                                id: context.rule.id,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                statusCode: statusCode,
                                contentType: contentType,
                                bodyText: bodyText,
                                forceNoCache: forceNoCache
                            )
                        }
                        responseOverrideEditorContext = nil
                    },
                    onSaveFile: { label, matchMode, matchPath, statusCode, contentType, fileURL, forceNoCache in
                        Task {
                            await viewModel.updateFileBackedResponseOverride(
                                id: context.rule.id,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                statusCode: statusCode,
                                contentType: contentType,
                                fileURL: fileURL,
                                forceNoCache: forceNoCache
                            )
                        }
                        responseOverrideEditorContext = nil
                    },
                    onSaveDirectory: { label, matchPath, directoryURL, forceNoCache in
                        Task {
                            await viewModel.updateDirectoryBackedResponseOverride(
                                id: context.rule.id,
                                label: label,
                                matchPath: matchPath,
                                directoryURL: directoryURL,
                                forceNoCache: forceNoCache
                            )
                        }
                        responseOverrideEditorContext = nil
                    },
                    onSaveBlock: { label, matchMode, matchPath, statusCode in
                        Task {
                            await viewModel.updateBlockResponseOverride(
                                id: context.rule.id,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                statusCode: statusCode
                            )
                        }
                        responseOverrideEditorContext = nil
                    },
                    onSaveMapRemote: { label, matchMode, matchPath, remoteHost, remotePort, remoteScheme, remotePath, allowLoopbackDestination, preserveHostHeader in
                        Task {
                            await viewModel.updateMapRemoteResponseOverride(
                                id: context.rule.id,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                remoteHost: remoteHost,
                                remotePort: remotePort,
                                remoteScheme: remoteScheme,
                                remotePath: remotePath,
                                allowLoopbackDestination: allowLoopbackDestination,
                                preserveHostHeader: preserveHostHeader
                            )
                        }
                        responseOverrideEditorContext = nil
                    },
                    onSaveLiveResponseRewrite: { label, matchMode, matchPath, rewrites in
                        Task {
                            await viewModel.updateLiveResponseRewriteRule(
                                id: context.rule.id,
                                label: label,
                                matchMode: matchMode,
                                matchPath: matchPath,
                                rewrites: rewrites
                            )
                        }
                        responseOverrideEditorContext = nil
                    },
                    onCancel: {
                        responseOverrideEditorContext = nil
                    }
                )
            }

        .sheet(item: $inspectedSession) { session in
            VStack {
                HStack {
                    Text("Captured Request").appFont(.headline, scale: viewModel.appTextSize.fontScale)
                    Spacer()
                    Button("Done") { inspectedSession = nil }
                }
                SessionDetailView(
                    session: session,
                    activeFindResultLocation: nil,
                    findQuery: nil,
                    findNavigationID: nil,
                    requestFindMatchContext: nil,
                    responseFindMatchContext: nil,
                    findDebugLoggingEnabled: false,
                    onAddBookmark: { viewModel.addBookmark(from: $0) },
                    onMapLocal: { selected in
                        inspectedSession = nil
                        mapLocalSheetContext = MapLocalSheetContext(session: selected)
                    },
                    onOpenMediaInfo: { selected in
                        presentationState.presentMediaInfo(sessionID: selected.id)
                        openWindow(id: "media-info")
                    },
                    onOpenHelpTopic: { topic in
                        presentationState.presentContextualHelp(topic: topic)
                        openWindow(id: "contextual-help")
                    },
                    openAPISchemaStore: viewModel.openAPISchemaStore
                )
            }
            .padding()
            .frame(minWidth: 720, minHeight: 560)
            .environment(\.appTextScale, viewModel.appTextSize.fontScale)
        }
    }
}
