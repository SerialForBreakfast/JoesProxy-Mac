import AppKit
import SwiftUI

struct VisualizationExportSheet: View {
    @Environment(\.appTextScale) private var appTextScale
    @StateObject private var viewModel: VisualizationExportViewModel
    let diagnosticInterlockCoordinator: MCPDiagnosticInterlockCoordinator?
    @State private var previewState = VisualizationExportPreviewState()
    @State private var exportErrorMessage: String?
    @State private var exportResult: VisualizationExportResult?
    @State private var interlockEvaluation: MCPDiagnosticInterlockEvaluation?
    private let pngExportCoordinator: VisualizationExportPNGExportCoordinator?
    let onDismiss: () -> Void
    let onOpenHelpTopic: ((MainWindowHelpTopic) -> Void)?

    @State private var isQuickHelpPresented = false

    init(
        context: VisualizationExportPresentationContext,
        diagnosticInterlockCoordinator: MCPDiagnosticInterlockCoordinator? = nil,
        pngExportCoordinator: VisualizationExportPNGExportCoordinator? = nil,
        onDismiss: @escaping () -> Void,
        onOpenHelpTopic: ((MainWindowHelpTopic) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: VisualizationExportViewModel(context: context))
        self.diagnosticInterlockCoordinator = diagnosticInterlockCoordinator
        self.pngExportCoordinator = pngExportCoordinator
        self.onDismiss = onDismiss
        self.onOpenHelpTopic = onOpenHelpTopic
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let coordinator = diagnosticInterlockCoordinator,
               let evaluation = interlockEvaluation,
               let diagnostic = currentDiagnosticKind {
                VisualizationExportInterlockBanner(
                    coordinator: coordinator,
                    diagnostic: diagnostic,
                    evaluation: evaluation,
                    textScale: appTextScale
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            if diagnosticInterlockCoordinator?.isMeasurementActive == true {
                Text("Measured with MCP effects suspended.")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            Divider()
            HStack(spacing: 0) {
                exportTypeSidebar
                Divider()
                previewPane
                Divider()
                inspectorPane
            }
            Divider()
            actionBar
        }
        .frame(minWidth: 1_080, idealWidth: 1_180, maxWidth: .infinity, minHeight: 680, idealHeight: 760, maxHeight: .infinity)
        .joesProxyResizableWorkspaceSheet(minWidth: 1_080, minHeight: 680)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("visualizationExportSheet")
        .alert("Export Failed", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    exportErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                exportErrorMessage = nil
            }
        } message: {
            Text(exportErrorMessage ?? "The visualization could not be exported.")
        }
        .task(id: viewModel.selectedExportType) {
            await refreshInterlockEvaluation()
        }
    }

    private var currentDiagnosticKind: MCPDiagnosticKind? {
        MCPDiagnosticRelevanceMatrix.diagnosticKind(for: viewModel.selectedExportType)
    }

    private func refreshInterlockEvaluation() async {
        guard let coordinator = diagnosticInterlockCoordinator,
              let diagnostic = currentDiagnosticKind else {
            interlockEvaluation = nil
            return
        }
        interlockEvaluation = await coordinator.evaluate(diagnostic: diagnostic)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Visualization")
                    .appFont(.title3, scale: appTextScale, weight: .semibold)
                Text(viewModel.context.sourceSummary)
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isQuickHelpPresented.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Export visualization help")
            .accessibilityLabel("Export visualization help")
            .accessibilityHint("Shows scope, redaction, PNG limitations, and provenance guidance.")
            .accessibilityIdentifier("visualizationExportHelpButton")
            .popover(isPresented: $isQuickHelpPresented, arrowEdge: .bottom) {
                VisualizationExportQuickHelp {
                    isQuickHelpPresented = false
                    onOpenHelpTopic?(.visualizationExport)
                }
            }
            Button("Cancel", action: onDismiss)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("visualizationExportCancelButton")
        }
        .padding(16)
    }

    private var exportTypeSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Visualization")
                .appFont(.headline, scale: appTextScale, weight: .semibold)

            ForEach(VisualizationExportViewModel.enabledExportTypes) { exportType in
                Button {
                    viewModel.selectedExportType = exportType
                    if viewModel.title == "" || VisualizationExportViewModel.enabledExportTypes.map(\.title).contains(viewModel.title) {
                        viewModel.title = exportType.title
                    }
                } label: {
                    HStack {
                        Image(systemName: iconName(for: exportType))
                            .frame(width: 18)
                        Text(exportType.title)
                            .appFont(.subheadline, scale: appTextScale, weight: exportType == viewModel.selectedExportType ? .semibold : .regular)
                        Spacer()
                        if exportType == viewModel.selectedExportType {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(exportType == viewModel.selectedExportType ? Color.accentColor.opacity(0.14) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(exportType.title)
                .accessibilityValue(exportType == viewModel.selectedExportType ? "Selected" : "Not selected")
                .accessibilityIdentifier("visualizationExportType-\(exportType.rawValue)")
            }

            Divider()

            summaryRow(label: "Scope", value: viewModel.context.sourceScope.summary)
            summaryRow(label: "Sessions", value: "\(viewModel.context.sessionCount)")
            if viewModel.context.hasActiveFilters {
                summaryRow(label: "Filtered", value: "\(viewModel.context.filteredSessionCount) of \(viewModel.context.totalSessionCount)")
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 250)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("visualizationExportTypeSidebar")
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .appFont(.headline, scale: appTextScale, weight: .semibold)
                    Text(viewModel.renderModel == nil ? "Renderer coming later" : previewTypeLabel)
                        .appFont(.caption, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                previewControls
                Text("\(viewModel.request.dimensions.width) x \(viewModel.request.dimensions.height)")
                    .appFont(.caption, scale: appTextScale, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Export pixel dimensions")
                    .accessibilityValue("\(viewModel.request.dimensions.width) x \(viewModel.request.dimensions.height)")
                    .accessibilityIdentifier("visualizationExportPixelDimensionsLabel")
            }

            if let renderModel = viewModel.renderModel, !renderModel.warnings.isEmpty {
                Label("\(renderModel.warnings.count) readability warning\(renderModel.warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("visualizationExportWarningSummary")
            }

            previewContent
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.22))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("visualizationExportPreview")
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var previewControls: some View {
        HStack(spacing: 6) {
            Button {
                previewState.zoomOut()
            } label: {
                Image(systemName: "minus")
            }
            .help("Zoom out")
            .accessibilityLabel("Zoom out")
            .accessibilityIdentifier("visualizationExportZoomOutButton")

            Text(previewState.zoomPercentText)
                .appFont(.caption, scale: appTextScale, design: .monospaced)
                .frame(width: 44)
                .accessibilityIdentifier("visualizationExportZoomPercentLabel")

            Button {
                previewState.zoomIn()
            } label: {
                Image(systemName: "plus")
            }
            .help("Zoom in")
            .accessibilityLabel("Zoom in")
            .accessibilityIdentifier("visualizationExportZoomInButton")

            Button("Fit Width") {
                previewState.fitWidth()
            }
            .help("Fit preview width")
            .accessibilityIdentifier("visualizationExportFitWidthButton")

            Button("Fit Height") {
                previewState.fitHeight()
            }
            .help("Fit preview height")
            .accessibilityIdentifier("visualizationExportFitHeightButton")

            Button("Reset") {
                previewState.reset()
            }
            .help("Reset preview zoom")
            .accessibilityIdentifier("visualizationExportResetPreviewZoomButton")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityIdentifier("visualizationExportPreviewControls")
    }

    @ViewBuilder
    private var previewContent: some View {
        if let renderModel = viewModel.renderModel {
            GeometryReader { proxy in
                // See `VisualizationExportPreviewMetrics.clampedScale` for why this is clamped
                // rather than left as the raw fit-scale × zoom-factor product.
                let scale = VisualizationExportPreviewMetrics.clampedScale(
                    containerSize: proxy.size,
                    dimensions: renderModel.request.dimensions,
                    fitMode: previewState.fitMode,
                    zoomFactor: previewState.zoomFactor
                )
                ScrollView([.horizontal, .vertical]) {
                    VisualizationExportRenderView(model: renderModel)
                        .scaleEffect(scale, anchor: .topLeading)
                        .offset(previewState.panOffset)
                        .frame(
                            width: CGFloat(renderModel.request.dimensions.width) * scale,
                            height: CGFloat(renderModel.request.dimensions.height) * scale,
                            alignment: .topLeading
                        )
                        .padding(16)
                        .gesture(
                            DragGesture()
                                .onEnded { value in
                                    previewState.pan(by: value.translation)
                                }
                        )
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !renderModel.warnings.isEmpty {
                    warningsOverlay(renderModel.warnings)
                        .padding(12)
                }
            }
            .onChange(of: viewModel.selectedExportType) { _, _ in
                previewState.reset()
            }
            .onChange(of: viewModel.dimensions) { _, _ in
                previewState.reset()
            }
        } else {
            placeholderPreview
                .padding(20)
        }
    }

    private var placeholderPreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.request.title)
                    .appFont(.title2, scale: appTextScale, weight: .semibold)
                if let subtitle = viewModel.request.subtitle {
                    Text(subtitle)
                        .appFont(.subheadline, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], alignment: .leading, spacing: 12) {
                previewMetric(title: "Type", value: viewModel.request.exportType.title)
                previewMetric(title: "Scope", value: viewModel.request.sourceScope.summary)
                previewMetric(title: "Theme", value: viewModel.request.theme.title)
                previewMetric(title: "Resolution", value: viewModel.request.dimensions.summary)
                previewMetric(title: "Redaction", value: "\(viewModel.request.redactionPolicy.summary.redactedCategories.count) categories")
                previewMetric(title: "Schema", value: "v\(viewModel.request.schemaVersion)")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Redaction Summary")
                    .appFont(.headline, scale: appTextScale, weight: .semibold)
                Text(redactionSummaryText)
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }

            validationSummary

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var validationSummary: some View {
        Group {
            if viewModel.validationIssues.isEmpty {
                Label(viewModel.exportUnavailableMessage, systemImage: viewModel.canExportPNG ? "checkmark.circle.fill" : "clock")
                    .appFont(.caption, scale: appTextScale, weight: .semibold)
                    .foregroundStyle(viewModel.canExportPNG ? .green : .secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.validationIssues.map(\.message), id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.orange)
                    }
                }
                .accessibilityIdentifier("visualizationExportValidationWarnings")
            }
        }
    }

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Export Settings") {
                    labeledTextField("Title", text: $viewModel.title, identifier: "visualizationExportTitleField")
                    labeledTextField("Subtitle", text: $viewModel.subtitle, identifier: "visualizationExportSubtitleField")

                    Picker("Resolution", selection: Binding(
                        get: { viewModel.dimensions.preset },
                        set: { viewModel.selectResolutionPreset($0) }
                    )) {
                        ForEach(VisualizationExportResolutionPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .accessibilityIdentifier("visualizationExportResolutionPicker")

                    if viewModel.dimensions.preset == .custom {
                        customDimensionStepper(
                            label: "Width",
                            value: viewModel.dimensions.width,
                            range: 640...8_192,
                            identifier: "visualizationExportCustomWidthStepper"
                        ) { newWidth in
                            viewModel.updateCustomDimensions(width: newWidth)
                        }
                        customDimensionStepper(
                            label: "Height",
                            value: viewModel.dimensions.height,
                            range: 360...8_192,
                            identifier: "visualizationExportCustomHeightStepper"
                        ) { newHeight in
                            viewModel.updateCustomDimensions(height: newHeight)
                        }
                    }

                    Picker("Theme", selection: $viewModel.theme) {
                        ForEach(VisualizationExportTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .accessibilityIdentifier("visualizationExportThemePicker")
                }

                section("Time Range") {
                    Toggle("Use custom time range", isOn: $viewModel.usesCustomTimeRange)
                        .accessibilityIdentifier("visualizationExportCustomTimeRangeToggle")
                    DatePicker("Start", selection: $viewModel.timeRangeStart)
                        .disabled(!viewModel.usesCustomTimeRange)
                        .accessibilityIdentifier("visualizationExportTimeRangeStartPicker")
                    DatePicker("End", selection: $viewModel.timeRangeEnd)
                        .disabled(!viewModel.usesCustomTimeRange)
                        .accessibilityIdentifier("visualizationExportTimeRangeEndPicker")
                }

                section("Chart Options") {
                    if viewModel.selectedExportType == .hostHealthSummary {
                        hostHealthChartOptions
                    } else if viewModel.selectedExportType == .requestWaterfall {
                        requestWaterfallChartOptions
                    } else {
                        sharedTimelineChartOptions
                    }
                }

                section("Annotations") {
                    Toggle("Show legend", isOn: $viewModel.includedMetadata.includeLegend)
                        .accessibilityIdentifier("visualizationExportIncludeLegendToggle")
                    Toggle("Show title block", isOn: $viewModel.includedMetadata.includeTitleBlock)
                    Toggle("Show request names", isOn: $viewModel.annotations.showRequestNames)
                    Toggle("Show host labels", isOn: $viewModel.annotations.showHostLabels)
                    Toggle("Show status codes", isOn: $viewModel.annotations.showStatusCodes)
                    Toggle("Show durations", isOn: $viewModel.annotations.showDurations)
                    Toggle("Show error badges", isOn: $viewModel.annotations.showErrorBadges)
                    Toggle("Show warning overlays", isOn: $viewModel.annotations.showWarningOverlays)
                }

                section("Metadata") {
                    Toggle("Include footer metadata", isOn: $viewModel.includedMetadata.includeFooterMetadata)
                        .accessibilityIdentifier("visualizationExportFooterMetadataToggle")
                    Toggle("Include data summary", isOn: $viewModel.includedMetadata.includeDataSummary)
                        .accessibilityIdentifier("visualizationExportDataSummaryToggle")
                }

                section("Privacy") {
                    Toggle("Redact auth headers", isOn: $viewModel.redactionPolicy.redactAuthHeaders)
                        .accessibilityIdentifier("visualizationExportRedactAuthToggle")
                    Toggle("Redact tokens", isOn: $viewModel.redactionPolicy.redactTokens)
                    Toggle("Redact cookies", isOn: $viewModel.redactionPolicy.redactCookies)
                    Toggle("Redact user identifiers", isOn: $viewModel.redactionPolicy.redactUserIdentifiers)
                    Toggle("Redact query parameters", isOn: $viewModel.redactionPolicy.redactQueryParameters)
                    Toggle("Redact raw bodies", isOn: $viewModel.redactionPolicy.redactRawBodies)
                    Toggle("Redact artwork and logos", isOn: $viewModel.redactionPolicy.redactArtworkAndLogos)
                    Toggle("Allow raw values", isOn: $viewModel.redactionPolicy.allowsRawValues)
                        .accessibilityIdentifier("visualizationExportAllowRawValuesToggle")
                }
            }
            .padding(16)
        }
        .frame(width: 310)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("visualizationExportInspector")
    }

    private var sharedTimelineChartOptions: some View {
        Group {
            Picker("Group by", selection: $viewModel.chartConfiguration.groupingMode) {
                ForEach(VisualizationExportGroupingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("visualizationExportGroupingPicker")

            Picker("Sort", selection: $viewModel.chartConfiguration.sortMode) {
                ForEach(VisualizationExportSortMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("visualizationExportSortPicker")

            Toggle("Failed only", isOn: $viewModel.chartConfiguration.showFailedOnly)
                .accessibilityIdentifier("visualizationExportFailedOnlyToggle")
            Toggle("Collapse duplicates", isOn: $viewModel.chartConfiguration.collapseDuplicates)
                .accessibilityIdentifier("visualizationExportCollapseDuplicatesToggle")
            Toggle("Normalize relative start time", isOn: $viewModel.chartConfiguration.normalizeRelativeStartTime)
                .accessibilityIdentifier("visualizationExportNormalizeStartToggle")
        }
    }

    private var hostHealthChartOptions: some View {
        Group {
            Picker("Bucket size", selection: hostHealthBucketSizeBinding) {
                ForEach(VisualizationExportHostHealthBucketSize.allCases) { bucketSize in
                    Text(bucketSize.title).tag(bucketSize)
                }
            }
            .accessibilityIdentifier("visualizationExportHostHealthBucketSizePicker")

            Toggle("Compare hosts", isOn: hostHealthComparisonBinding)
                .accessibilityIdentifier("visualizationExportHostHealthComparisonToggle")
        }
    }

    private var requestWaterfallChartOptions: some View {
        Group {
            Picker("Sort", selection: $viewModel.chartConfiguration.sortMode) {
                ForEach(VisualizationExportSortMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("visualizationExportWaterfallSortPicker")

            Toggle("Highlight slowest requests", isOn: waterfallHighlightSlowestBinding)
                .accessibilityIdentifier("visualizationExportWaterfallHighlightSlowestToggle")
            Toggle("Setup path only", isOn: waterfallSetupPathOnlyBinding)
                .accessibilityIdentifier("visualizationExportWaterfallSetupPathOnlyToggle")
            Toggle("Failed only", isOn: $viewModel.chartConfiguration.showFailedOnly)
                .accessibilityIdentifier("visualizationExportFailedOnlyToggle")
            Toggle("Normalize relative start time", isOn: $viewModel.chartConfiguration.normalizeRelativeStartTime)
                .accessibilityIdentifier("visualizationExportNormalizeStartToggle")
        }
    }

    private var waterfallHighlightSlowestBinding: Binding<Bool> {
        Binding(
            get: { viewModel.chartConfiguration.waterfallHighlightSlowestRequests },
            set: { enabled in
                var configuration = viewModel.chartConfiguration
                configuration.setWaterfallHighlightSlowestRequests(enabled)
                viewModel.chartConfiguration = configuration
            }
        )
    }

    private var waterfallSetupPathOnlyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.chartConfiguration.waterfallSetupPathOnly },
            set: { enabled in
                var configuration = viewModel.chartConfiguration
                configuration.setWaterfallSetupPathOnly(enabled)
                viewModel.chartConfiguration = configuration
            }
        )
    }

    private var hostHealthBucketSizeBinding: Binding<VisualizationExportHostHealthBucketSize> {
        Binding(
            get: { viewModel.chartConfiguration.hostHealthBucketSize },
            set: { newValue in
                var configuration = viewModel.chartConfiguration
                configuration.setHostHealthBucketSize(newValue)
                viewModel.chartConfiguration = configuration
            }
        )
    }

    private var hostHealthComparisonBinding: Binding<Bool> {
        Binding(
            get: { viewModel.chartConfiguration.hostHealthComparisonEnabled },
            set: { enabled in
                var configuration = viewModel.chartConfiguration
                configuration.setHostHealthComparisonMode(enabled)
                viewModel.chartConfiguration = configuration
            }
        )
    }

    private var previewTypeLabel: String {
        switch viewModel.selectedExportType {
        case .sessionTimeline:
            return "Session Timeline"
        case .hostHealthSummary:
            return "Host Health Summary"
        case .requestWaterfall:
            return "Request Waterfall"
        default:
            return viewModel.selectedExportType.title
        }
    }


    private var actionBar: some View {
        HStack {
            Button {
                viewModel.resetToDefaults()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .accessibilityIdentifier("visualizationExportResetButton")

            Spacer()

            Button {
                copyPreviewToPasteboard()
            } label: {
                Label("Copy Preview", systemImage: "document.on.document")
            }
            .disabled(!viewModel.canExportPNG)
            .help("Copy the current visualization preview as a PNG image.")
            .accessibilityIdentifier("visualizationExportCopyPreviewButton")

            Button {
                exportPNG()
            } label: {
                Label("Export PNG", systemImage: "square.and.arrow.down")
            }
            .disabled(!viewModel.canExportPNG)
            .help(viewModel.exportUnavailableMessage)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Export PNG")
            .accessibilityValue(viewModel.exportUnavailableMessage)
            .accessibilityIdentifier("visualizationExportPNGButton")
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }

    private func warningsOverlay(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.caption, scale: appTextScale)
            }
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("visualizationExportReadabilityWarnings")
    }

    private func copyPreviewToPasteboard() {
        guard let renderModel = viewModel.renderModel else {
            return
        }

        do {
            let pngData = try VisualizationExportPNGRenderer().renderPNGData(for: renderModel)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(pngData, forType: .png)
            exportResult = VisualizationExportPNGRenderer().makeResult(
                for: renderModel,
                imageFileURL: nil,
                imageByteCount: pngData.count
            )
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func exportPNG() {
        guard let renderModel = viewModel.renderModel else {
            return
        }

        do {
            let coordinator = pngExportCoordinator ?? VisualizationExportPNGExportCoordinator()
            switch try coordinator.export(model: renderModel) {
            case .cancelled:
                return
            case .exported(let result):
                exportResult = result
                onDismiss()
            }
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private var redactionSummaryText: String {
        let summary = viewModel.request.redactionPolicy.summary
        if summary.redactedCategories.isEmpty {
            return summary.allowsRawValues ? "Raw values are allowed." : "No redaction categories are enabled."
        }
        var parts = [summary.redactedCategories.joined(separator: ", ")]
        if summary.customSensitiveKeyCount > 0 {
            parts.append("\(summary.customSensitiveKeyCount) custom keys")
        }
        if summary.allowsRawValues {
            parts.append("raw values allowed")
        }
        return parts.joined(separator: "; ")
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .appFont(.headline, scale: appTextScale, weight: .semibold)
            content()
        }
    }

    private func labeledTextField(_ label: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .appFont(.caption, scale: appTextScale, weight: .semibold)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(identifier)
        }
    }

    private func customDimensionStepper(
        label: String,
        value: Int,
        range: ClosedRange<Int>,
        identifier: String,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        Stepper(value: Binding(
            get: { value },
            set: onChange
        ), in: range, step: 16) {
            Text("\(label): \(value) px")
                .appFont(.caption, scale: appTextScale)
        }
        .accessibilityIdentifier(identifier)
    }

    private func previewMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(.caption, scale: appTextScale, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .appFont(.subheadline, scale: appTextScale)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func summaryRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .appFont(.caption2, scale: appTextScale, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .appFont(.caption, scale: appTextScale)
                .lineLimit(2)
        }
    }

    private func iconName(for exportType: VisualizationExportType) -> String {
        switch exportType {
        case .sessionTimeline:
            return "calendar"
        case .requestWaterfall:
            return "list.bullet.rectangle"
        case .hostHealthSummary:
            return "waveform.path.ecg"
        case .latencyDistribution:
            return "chart.bar"
        case .errorHeatmap:
            return "square.grid.3x3"
        case .hlsPlaybackFlow:
            return "play.circle"
        case .mediaAssetDeliveryTimeline:
            return "waveform.path"
        case .adAndCompanionAssetTimeline:
            return "rectangle.badge.plus"
        case .variantSwitchTimeline:
            return "arrow.triangle.swap"
        case .timedMetadataTimeline:
            return "tag"
        case .contractViolationSummary:
            return "shield"
        }
    }
}

private extension VisualizationExportTheme {
    var title: String {
        switch self {
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case .presentation:
            return "Presentation"
        }
    }
}

private extension VisualizationExportDimensions {
    var summary: String {
        "\(preset.title) \(width) x \(height)"
    }
}

private extension VisualizationExportGroupingMode {
    var title: String {
        switch self {
        case .none:
            return "None"
        case .host:
            return "Host"
        case .requestRole:
            return "Request role"
        }
    }
}

private extension VisualizationExportSortMode {
    var title: String {
        switch self {
        case .startTime:
            return "Start time"
        case .durationDescending:
            return "Duration descending"
        }
    }
}

private struct VisualizationExportInterlockBanner: View {
    @ObservedObject var coordinator: MCPDiagnosticInterlockCoordinator
    let diagnostic: MCPDiagnosticKind
    let evaluation: MCPDiagnosticInterlockEvaluation
    let textScale: CGFloat

    var body: some View {
        MCPDiagnosticInterlockBanner(
            coordinator: coordinator,
            diagnostic: diagnostic,
            evaluation: evaluation,
            textScale: textScale,
            onAcknowledge: {}
        )
    }
}
