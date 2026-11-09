import SwiftUI

struct VisualizationExportRenderView: View {
    let model: VisualizationExportRenderModel

    var body: some View {
        switch model {
        case .sessionTimeline(let timeline):
            SessionTimelineExportRenderView(model: timeline)
        case .hostHealthSummary(let hostHealth):
            HostHealthSummaryExportRenderView(model: hostHealth)
        case .requestWaterfall(let waterfall):
            RequestWaterfallExportRenderView(model: waterfall)
        }
    }
}

private struct HostHealthSummaryExportRenderView: View {
    let model: HostHealthSummaryExportModel

    private var colors: VisualizationExportThemeColors {
        VisualizationExportThemeColors(theme: model.request.theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.request.includedMetadata.includeTitleBlock {
                titleBlock
            }

            if model.comparisonMode {
                comparisonGrid
            } else if let host = model.hosts.first {
                aggregatePanel(host)
            }

            if model.request.includedMetadata.includeLegend {
                legend
            }

            if model.request.includedMetadata.includeFooterMetadata {
                footer
            }
        }
        .padding(44)
        .frame(
            width: CGFloat(model.request.dimensions.width),
            height: CGFloat(model.request.dimensions.height),
            alignment: .topLeading
        )
        .background(colors.background)
        .foregroundStyle(colors.primaryText)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.request.title)
                .font(.system(size: 34, weight: .semibold))
            if let subtitle = model.request.subtitle {
                Text(subtitle)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(colors.secondaryText)
            }
            Text(summaryLine)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(colors.secondaryText)
        }
    }

    private var summaryLine: String {
        let requestCount = model.hosts.reduce(0) { $0 + $1.requestCount }
        let hostLabel = model.comparisonMode ? "\(model.hosts.count) hosts" : "aggregate"
        return "\(requestCount) requests • \(hostLabel) • \(model.bucketSize.title) buckets"
    }

    private var comparisonGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(model.hosts) { host in
                hostPanel(host, compact: true)
            }
        }
    }

    private func aggregatePanel(_ host: HostHealthSummaryExportModel.HostSummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            summaryCards(host)
            chartsPanel(host, height: chartHeight(compact: false))
        }
    }

    private func hostPanel(
        _ host: HostHealthSummaryExportModel.HostSummary,
        compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(host.host)
                .font(.system(size: compact ? 18 : 22, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            summaryCards(host)
            chartsPanel(host, height: chartHeight(compact: compact))
        }
        .padding(14)
        .background(colors.alternatingRow)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func summaryCards(_ host: HostHealthSummaryExportModel.HostSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
            metricCard("Requests", value: "\(host.requestCount)")
            metricCard("Success", value: "\(host.successCount)")
            metricCard("Errors", value: "\(host.errorCount)")
            metricCard("4xx", value: "\(host.clientErrorCount)")
            metricCard("5xx", value: "\(host.serverErrorCount)")
            metricCard("Timeouts", value: "\(host.timeoutCount)")
            metricCard("p50", value: formatLatency(host.p50LatencyMs))
            metricCard("p95", value: formatLatency(host.p95LatencyMs))
            if let peak = host.peakErrorWindow {
                metricCard(
                    "Peak Errors",
                    value: "\(peak.errorCount) @ \(peak.startOffset.formattedForExportSeconds())"
                )
            }
            if host.mcpAttributedRequestCount > 0 {
                metricCard("MCP Effect", value: "\(host.mcpAttributedRequestCount) of \(host.requestCount)")
            }
        }
    }

    private func chartsPanel(
        _ host: HostHealthSummaryExportModel.HostSummary,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Request Volume, Latency Trend, and Error Markers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colors.secondaryText)
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(colors.grid.opacity(0.35))
                    HStack(alignment: .bottom, spacing: max(1, width / CGFloat(max(host.buckets.count * 6, 1)))) {
                        ForEach(host.buckets) { bucket in
                            bucketColumn(bucket, maxCount: maxBucketCount(host), height: height)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func bucketColumn(
        _ bucket: HostHealthSummaryExportModel.TimeBucket,
        maxCount: Int,
        height: CGFloat
    ) -> some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            if let latency = bucket.medianLatencyMs {
                Circle()
                    .fill(colors.redirect)
                    .frame(width: 6, height: 6)
                    .offset(y: -latencyOffset(latency, height: height))
            }
            if bucket.errorCount > 0 {
                Circle()
                    .fill(colors.failure)
                    .frame(width: 8, height: 8)
            }
            if bucket.mcpAttributedRequestCount > 0 {
                Circle()
                    .fill(Color.purple)
                    .frame(width: 6, height: 6)
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(colors.success.opacity(0.85))
                .frame(
                    width: 10,
                    height: max(4, CGFloat(bucket.requestCount) / CGFloat(max(maxCount, 1)) * (height * 0.55))
                )
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func metricCard(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(colors.secondaryText)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(colors.background.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var legend: some View {
        HStack(spacing: 18) {
            legendItem("Volume", color: colors.success)
            legendItem("Median Latency", color: colors.redirect)
            legendItem("Errors", color: colors.failure)
            if hasMCPAttribution {
                legendItem("MCP Effect", color: .purple)
            }
        }
        .font(.system(size: 13, weight: .medium))
    }

    private var hasMCPAttribution: Bool {
        model.hosts.contains { $0.mcpAttributedRequestCount > 0 }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.warnings.isEmpty {
                Text("Warnings: \(model.warnings.joined(separator: " "))")
                    .foregroundStyle(colors.warning)
            }
            Text("Redaction: \(redactionSummaryText). Provenance: \(provenanceSummaryText).")
                .foregroundStyle(colors.secondaryText)
        }
        .font(.system(size: 12, weight: .regular))
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
        }
    }

    private func chartHeight(compact: Bool) -> CGFloat {
        compact ? 120 : 180
    }

    private func maxBucketCount(_ host: HostHealthSummaryExportModel.HostSummary) -> Int {
        max(host.buckets.map(\.requestCount).max() ?? 1, 1)
    }

    private func latencyOffset(_ latencyMs: Double, height: CGFloat) -> CGFloat {
        let normalized = min(latencyMs / 2_000, 1)
        return CGFloat(normalized) * (height * 0.35)
    }

    private func formatLatency(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        if value < 1_000 {
            return "\(Int(value.rounded()))ms"
        }
        return String(format: "%.2fs", value / 1_000)
    }

    private var redactionSummaryText: String {
        let summary = model.request.redactionPolicy.summary
        guard !summary.redactedCategories.isEmpty else {
            return summary.allowsRawValues ? "raw values allowed" : "none"
        }
        return summary.redactedCategories.joined(separator: ", ")
    }

    private var provenanceSummaryText: String {
        var parts = ["proxy-only"]
        if model.request.provenance.isPartialCapture {
            parts.append("partial capture")
        }
        if model.request.provenance.hasStrippedBodies {
            parts.append("bodies stripped")
        }
        return parts.joined(separator: ", ")
    }
}

private struct RequestWaterfallExportRenderView: View {
    let model: RequestWaterfallExportModel

    private var colors: VisualizationExportThemeColors {
        VisualizationExportThemeColors(theme: model.request.theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.request.includedMetadata.includeTitleBlock {
                titleBlock
            }

            waterfallHeader
            waterfallRows

            if model.request.includedMetadata.includeLegend {
                legend
            }

            if model.request.includedMetadata.includeFooterMetadata {
                footer
            }
        }
        .padding(44)
        .frame(
            width: CGFloat(model.request.dimensions.width),
            height: CGFloat(model.request.dimensions.height),
            alignment: .topLeading
        )
        .background(colors.background)
        .foregroundStyle(colors.primaryText)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.request.title)
                .font(.system(size: 34, weight: .semibold))
            if let subtitle = model.request.subtitle {
                Text(subtitle)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(colors.secondaryText)
            }
            Text("\(model.rows.count) requests • \(model.totalDuration.formattedForExportSeconds()) sequencing window")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(colors.secondaryText)
        }
    }

    private var waterfallHeader: some View {
        HStack(spacing: 10) {
            Text("Category")
                .frame(width: 130, alignment: .leading)
            Text("Host")
                .frame(width: 180, alignment: .leading)
            Text("Request")
                .frame(width: 250, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("0s")
                    Spacer()
                    Text(model.totalDuration.formattedForExportSeconds())
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(colors.secondaryText)
                Rectangle()
                    .fill(colors.grid)
                    .frame(height: 1)
            }
        }
        .font(.system(size: 13, weight: .semibold))
    }

    private var waterfallRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(model.rows.prefix(maxVisibleRows()).enumerated()), id: \.element.id) { index, row in
                waterfallRow(row, index: index)
            }

            if model.rows.count > maxVisibleRows() {
                Text("\(model.rows.count - maxVisibleRows()) more requests omitted from this preview scale.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.secondaryText)
                    .padding(.top, 4)
            }
        }
    }

    private func waterfallRow(_ row: RequestWaterfallExportModel.Row, index: Int) -> some View {
        HStack(spacing: 10) {
            Text(row.categoryTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(categoryColor(for: row.categoryLane))
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)

            Text(row.host)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(colors.secondaryText)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.method)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(colors.badgeText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(colors.methodBadge)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if model.request.annotations.showStatusCodes {
                        Text(row.statusLabel)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(row.isFailure ? colors.failure : colors.secondaryText)
                    }
                    if row.mcpEffectAnnotation != nil {
                        mcpEffectBadge
                    }
                }
                if model.request.annotations.showRequestNames {
                    Text(row.pathSummary)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(colors.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: 250, alignment: .leading)

            GeometryReader { proxy in
                let availableWidth = max(proxy.size.width, 1)
                let x = CGFloat(row.startOffset / model.totalDuration) * availableWidth
                let width = max(CGFloat(row.duration / model.totalDuration) * availableWidth, 3)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(index.isMultiple(of: 2) ? colors.alternatingRow : Color.clear)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(for: row))
                        .overlay {
                            if row.mcpEffectAnnotation != nil {
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.purple, lineWidth: 2)
                            }
                        }
                        .overlay {
                            if row.isSlowestHighlight {
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(colors.warning, lineWidth: 2)
                            }
                        }
                        .frame(width: min(width, availableWidth - min(x, availableWidth)), height: 16)
                        .offset(x: min(x, availableWidth - 1))
                    if model.request.annotations.showDurations {
                        Text(row.duration.formattedForExportMilliseconds())
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(colors.primaryText)
                            .lineLimit(1)
                            .offset(x: min(x + width + 5, max(0, availableWidth - 120)))
                    }
                }
            }
            .frame(height: 34)
        }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            legendItem("Success", color: colors.success)
            legendItem("Redirect", color: colors.redirect)
            legendItem("Error / Failed", color: colors.failure)
            if model.highlightSlowestRequests {
                legendItem("Slowest", color: colors.warning)
            }
            if hasMCPAttribution {
                legendItem("MCP Effect", color: .purple)
            }
        }
        .font(.system(size: 13, weight: .medium))
    }

    private var hasMCPAttribution: Bool {
        model.rows.contains { $0.mcpEffectAnnotation != nil }
    }

    /// Compact "MCP" marker for a request captured under an active MCP effect (AJ-3). Immutable —
    /// sourced from the row's capture-time attribution snapshot, never a live rule lookup.
    private var mcpEffectBadge: some View {
        Text("MCP")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.purple)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.warnings.isEmpty {
                Text("Warnings: \(model.warnings.joined(separator: " "))")
                    .foregroundStyle(colors.warning)
            }
            Text("Redaction: \(redactionSummaryText). Provenance: \(provenanceSummaryText).")
                .foregroundStyle(colors.secondaryText)
        }
        .font(.system(size: 12, weight: .regular))
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
        }
    }

    private func barColor(for row: RequestWaterfallExportModel.Row) -> Color {
        if row.isFailure {
            return colors.failure
        }
        if row.statusLabel.hasPrefix("3") {
            return colors.redirect
        }
        return colors.success
    }

    private func categoryColor(for lane: TimelineLane) -> Color {
        switch lane {
        case .authConfig, .drmLicense:
            return colors.redirect
        case .manifest:
            return colors.warning
        case .mediaSegments, .imagesAssets:
            return colors.neutral
        case .adsAnalytics:
            return colors.secondaryText
        case .errorsRetries:
            return colors.failure
        case .api, .pinned:
            return colors.success
        }
    }

    private func maxVisibleRows() -> Int {
        max(6, min(model.rows.count, Int((CGFloat(model.request.dimensions.height) - 260) / 38)))
    }

    private var redactionSummaryText: String {
        let summary = model.request.redactionPolicy.summary
        guard !summary.redactedCategories.isEmpty else {
            return summary.allowsRawValues ? "raw values allowed" : "none"
        }
        return summary.redactedCategories.joined(separator: ", ")
    }

    private var provenanceSummaryText: String {
        var parts = ["proxy-only"]
        if model.request.provenance.isPartialCapture {
            parts.append("partial capture")
        }
        if model.request.provenance.hasStrippedBodies {
            parts.append("bodies stripped")
        }
        return parts.joined(separator: ", ")
    }
}

private struct SessionTimelineExportRenderView: View {
    let model: SessionTimelineExportModel

    private var colors: VisualizationExportThemeColors {
        VisualizationExportThemeColors(theme: model.request.theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.request.includedMetadata.includeTitleBlock {
                titleBlock
            }

            timelineHeader
            timelineRows

            if model.request.includedMetadata.includeLegend {
                legend
            }

            if model.request.includedMetadata.includeFooterMetadata {
                footer
            }
        }
        .padding(44)
        .frame(width: CGFloat(model.request.dimensions.width), height: CGFloat(model.request.dimensions.height), alignment: .topLeading)
        .background(colors.background)
        .foregroundStyle(colors.primaryText)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.request.title)
                .font(.system(size: 34, weight: .semibold))
            if let subtitle = model.request.subtitle {
                Text(subtitle)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(colors.secondaryText)
            }
            Text("\(model.rows.count) requests • \(model.totalDuration.formattedForExportSeconds()) window")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(colors.secondaryText)
        }
    }

    private var timelineHeader: some View {
        HStack(spacing: 12) {
            Text("Request")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 360, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("0s")
                    Spacer()
                    Text(model.totalDuration.formattedForExportSeconds())
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(colors.secondaryText)
                Rectangle()
                    .fill(colors.grid)
                    .frame(height: 1)
            }
        }
    }

    private var timelineRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(model.rows.prefix(maxVisibleRows()).enumerated()), id: \.element.id) { index, row in
                timelineRow(row, index: index)
            }

            if model.rows.count > maxVisibleRows() {
                Text("\(model.rows.count - maxVisibleRows()) more requests omitted from this preview scale.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.secondaryText)
                    .padding(.top, 4)
            }
        }
    }

    private func timelineRow(_ row: SessionTimelineExportModel.Row, index: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.method)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(colors.badgeText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(colors.methodBadge)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if model.request.annotations.showHostLabels {
                        Text(row.host)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    }
                    if row.mcpEffectAnnotation != nil {
                        mcpEffectBadge
                    }
                }
                if model.request.annotations.showRequestNames {
                    Text(row.pathSummary)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(colors.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: 360, alignment: .leading)

            GeometryReader { proxy in
                let availableWidth = max(proxy.size.width, 1)
                let x = CGFloat(row.startOffset / model.totalDuration) * availableWidth
                let width = max(CGFloat(row.duration / model.totalDuration) * availableWidth, 3)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(index.isMultiple(of: 2) ? colors.alternatingRow : Color.clear)
                    Rectangle()
                        .fill(color(for: row))
                        .frame(width: min(width, availableWidth - min(x, availableWidth)), height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay {
                            if row.mcpEffectAnnotation != nil {
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.purple, lineWidth: 2)
                                    .frame(width: min(width, availableWidth - min(x, availableWidth)), height: 16)
                            }
                        }
                        .offset(x: min(x, availableWidth - 1))
                    if model.request.annotations.showDurations || model.request.annotations.showStatusCodes {
                        Text(rowLabel(for: row))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(colors.primaryText)
                            .lineLimit(1)
                            .offset(x: min(x + width + 5, max(0, availableWidth - 120)))
                    }
                }
            }
            .frame(height: 31)
        }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            legendItem("Success", color: colors.success)
            legendItem("Redirect", color: colors.redirect)
            legendItem("Error / Failed", color: colors.failure)
            legendItem("Tunnel / Pending", color: colors.neutral)
            if hasMCPAttribution {
                legendItem("MCP Effect", color: .purple)
            }
        }
        .font(.system(size: 13, weight: .medium))
    }

    private var hasMCPAttribution: Bool {
        model.rows.contains { $0.mcpEffectAnnotation != nil }
    }

    /// Compact "MCP" marker for a request captured under an active MCP effect (AJ-3). Immutable —
    /// sourced from the row's capture-time attribution snapshot, never a live rule lookup.
    private var mcpEffectBadge: some View {
        Text("MCP")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.purple)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.warnings.isEmpty {
                Text("Warnings: \(model.warnings.joined(separator: " "))")
                    .foregroundStyle(colors.warning)
            }
            Text("Redaction: \(redactionSummaryText). Provenance: \(provenanceSummaryText).")
                .foregroundStyle(colors.secondaryText)
        }
        .font(.system(size: 12, weight: .regular))
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
        }
    }

    private func color(for row: SessionTimelineExportModel.Row) -> Color {
        if row.isFailure {
            return colors.failure
        }
        if row.statusLabel.hasPrefix("3") {
            return colors.redirect
        }
        if row.inspectionKind == .tunneledTLS || row.statusLabel == "Pending" {
            return colors.neutral
        }
        return colors.success
    }

    private func rowLabel(for row: SessionTimelineExportModel.Row) -> String {
        var parts: [String] = []
        if model.request.annotations.showStatusCodes {
            parts.append(row.statusLabel)
        }
        if model.request.annotations.showDurations {
            parts.append(row.duration.formattedForExportMilliseconds())
        }
        return parts.joined(separator: " • ")
    }

    private func maxVisibleRows() -> Int {
        max(6, min(model.rows.count, Int((CGFloat(model.request.dimensions.height) - 260) / 36)))
    }

    private var redactionSummaryText: String {
        let summary = model.request.redactionPolicy.summary
        guard !summary.redactedCategories.isEmpty else {
            return summary.allowsRawValues ? "raw values allowed" : "none"
        }
        return summary.redactedCategories.joined(separator: ", ")
    }

    private var provenanceSummaryText: String {
        var parts = ["proxy-only"]
        if model.request.provenance.isPartialCapture {
            parts.append("partial capture")
        }
        if model.request.provenance.hasStrippedBodies {
            parts.append("bodies stripped")
        }
        return parts.joined(separator: ", ")
    }
}

private struct VisualizationExportThemeColors {
    let background: Color
    let primaryText: Color
    let secondaryText: Color
    let grid: Color
    let alternatingRow: Color
    let success: Color
    let redirect: Color
    let failure: Color
    let neutral: Color
    let warning: Color
    let methodBadge: Color
    let badgeText: Color

    init(theme: VisualizationExportTheme) {
        switch theme {
        case .light:
            background = Color(red: 0.97, green: 0.98, blue: 0.98)
            primaryText = Color(red: 0.08, green: 0.10, blue: 0.12)
            secondaryText = Color(red: 0.32, green: 0.36, blue: 0.42)
            grid = Color(red: 0.78, green: 0.81, blue: 0.86)
            alternatingRow = Color.black.opacity(0.035)
            success = Color(red: 0.12, green: 0.55, blue: 0.32)
            redirect = Color(red: 0.18, green: 0.42, blue: 0.75)
            failure = Color(red: 0.82, green: 0.20, blue: 0.20)
            neutral = Color(red: 0.50, green: 0.54, blue: 0.60)
            warning = Color(red: 0.78, green: 0.44, blue: 0.06)
            methodBadge = Color(red: 0.12, green: 0.18, blue: 0.24)
            badgeText = .white
        case .dark:
            background = Color(red: 0.07, green: 0.08, blue: 0.10)
            primaryText = Color(red: 0.93, green: 0.95, blue: 0.97)
            secondaryText = Color(red: 0.62, green: 0.67, blue: 0.73)
            grid = Color.white.opacity(0.16)
            alternatingRow = Color.white.opacity(0.035)
            success = Color(red: 0.25, green: 0.72, blue: 0.42)
            redirect = Color(red: 0.34, green: 0.55, blue: 0.94)
            failure = Color(red: 0.95, green: 0.32, blue: 0.32)
            neutral = Color(red: 0.55, green: 0.58, blue: 0.65)
            warning = Color(red: 0.95, green: 0.65, blue: 0.20)
            methodBadge = Color.white.opacity(0.12)
            badgeText = primaryText
        case .presentation:
            background = Color(red: 0.02, green: 0.03, blue: 0.06)
            primaryText = .white
            secondaryText = Color(red: 0.78, green: 0.82, blue: 0.88)
            grid = Color(red: 0.28, green: 0.32, blue: 0.45)
            alternatingRow = Color.white.opacity(0.045)
            success = Color(red: 0.13, green: 0.80, blue: 0.55)
            redirect = Color(red: 0.40, green: 0.62, blue: 1.00)
            failure = Color(red: 1.00, green: 0.30, blue: 0.38)
            neutral = Color(red: 0.74, green: 0.76, blue: 0.84)
            warning = Color(red: 1.00, green: 0.72, blue: 0.24)
            methodBadge = Color(red: 0.18, green: 0.22, blue: 0.38)
            badgeText = .white
        }
    }
}

private extension TimeInterval {
    func formattedForExportSeconds() -> String {
        String(format: "%.2fs", self)
    }

    func formattedForExportMilliseconds() -> String {
        if self < 1 {
            return "\(Int((self * 1_000).rounded()))ms"
        }
        return String(format: "%.2fs", self)
    }
}
