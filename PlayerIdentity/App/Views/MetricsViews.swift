import Charts
import SwiftUI

/// §39 / §48.3 server details: chart card — header with the 24 h uptime chip, ping (ms) and player charts with
/// offline ranges shaded, a legend; "no data" for an empty series. Axes, grid and legend use the tokens.
struct MetricsSection: View {
    let samples: [MetricSample]
    let serverID: UUID
    let now: Date
    /// Consecutive failed sample writes (a red line from the second one on).
    var writeFailure: MetricsRecorder.WriteFailure?

    var body: some View {
        let series = MetricsAnalysis.series(samples, serverID: serverID, now: now)
        let uptime = MetricsAnalysis.uptime(samples, serverID: serverID, now: now)
        ThemedCard {
            CardHeader(symbol: "waveform.path.ecg", title: L10n.text(.metricsTitle)) {
                if let uptime {
                    let chip = MetricsChart.uptimeChip(uptime)
                    StatusChip(symbol: chip.symbol, text: chip.text, tone: chip.tone)
                        .accessibilityIdentifier("metricsUptime")
                }
            }
        } content: {
            if let text = MetricsChart.writeFailureText(writeFailure, now: now) {
                Text(text)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.redText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("metricsWriteFailure")
            }
            if series.isEmpty {
                HStack(spacing: Space.s2) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(TypeScale.symbol)
                        .foregroundStyle(Palette.text3)
                        .accessibilityHidden(true)
                    Text(L10n.text(.metricsNoData))
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text2)
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.Chart.emptyHeight)
                .background(RoundedRectangle(cornerRadius: Radius.inner).fill(Palette.inset))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("metricsNoData")
            } else {
                let offline = MetricsChart.offlineRanges(series, now: now)
                chart(L10n.text(.metricsPing), points: MetricsChart.points(series, \.ping),
                      color: MetricsChart.pingColor, offline: offline)
                chart(L10n.text(.metricsPlayers), points: MetricsChart.points(series, \.players),
                      color: MetricsChart.playersColor, offline: offline)
                legend(hasOffline: !offline.isEmpty)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(L10n.text(.metricsTitle))
    }

    private func chart(_ title: String, points: [MetricsChart.Point], color: Color,
                       offline: [MetricsChart.OfflineRange]) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(title)
                .font(TypeScale.captionStrong)
                .foregroundStyle(Palette.text2)
                .accessibilityHidden(true)
            Chart {
                ForEach(Array(offline.enumerated()), id: \.offset) { _, range in
                    RectangleMark(xStart: .value(L10n.text(.metricsTime), range.start),
                                  xEnd: .value(L10n.text(.metricsTime), range.end))
                        .foregroundStyle(Palette.redTint)
                }
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    // One line per online run: the line breaks at an outage instead of bridging it.
                    LineMark(x: .value(L10n.text(.metricsTime), point.ts), y: .value(title, point.value),
                             series: .value(L10n.text(.metricsOffline), point.segment))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: Metrics.Chart.line))
                    PointMark(x: .value(L10n.text(.metricsTime), point.ts), y: .value(title, point.value))
                        .foregroundStyle(color)
                        .symbolSize(Metrics.Chart.point)
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-MetricsAnalysis.dayWindow)...now)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: Metrics.Chart.axisHours)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: Metrics.Chart.gridLine))
                        .foregroundStyle(Palette.separator)
                    AxisTick(stroke: StrokeStyle(lineWidth: Metrics.Chart.gridLine))
                        .foregroundStyle(Palette.borderStrong)
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.text2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: Metrics.Chart.gridLine))
                        .foregroundStyle(Palette.separator)
                    AxisValueLabel()
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.text2)
                }
            }
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                plot.background(Palette.inset)
            }
            .environment(\.locale, Locale(identifier: L10n.currentLanguage.rawValue))
            .frame(height: Metrics.Chart.height)
            .accessibilityLabel(title)
            .accessibilityValue(MetricsChart.summary(points.map(\.value)))
        }
    }

    private func legend(hasOffline: Bool) -> some View {
        HStack(spacing: Space.s4) {
            legendItem(L10n.text(.metricsPing), color: MetricsChart.pingColor)
            legendItem(L10n.text(.metricsPlayers), color: MetricsChart.playersColor)
            if hasOffline {
                HStack(spacing: Space.s1) {
                    RoundedRectangle(cornerRadius: Radius.badge / 2)
                        .fill(Palette.redTint)
                        .overlay(RoundedRectangle(cornerRadius: Radius.badge / 2).strokeBorder(Palette.red, lineWidth: Metrics.hairline))
                        .frame(width: Metrics.Chart.legendSwatch.width, height: Metrics.Chart.legendSwatch.height)
                    Text(L10n.text(.metricsOffline))
                }
            }
            Spacer(minLength: 0)
        }
        .font(TypeScale.caption)
        .foregroundStyle(Palette.text2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("metricsLegend")
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: Space.s1) {
            Capsule()
                .fill(color)
                .frame(width: Metrics.Chart.legendSwatch.width, height: Metrics.Chart.line * 2)
            Text(title)
        }
    }
}

/// Pure pieces of the metrics card (tested without rendering).
enum MetricsChart {
    static let pingColor = Palette.accent
    static let playersColor = Palette.text2

    /// "Samples could not be written in the last N hours" after two or more failed writes in a row.
    static func writeFailureText(_ failure: MetricsRecorder.WriteFailure?, now: Date) -> String? {
        guard let failure, failure.count >= 2 else { return nil }
        let hours = max(1, Int((now.timeIntervalSince(failure.since) / 3600).rounded(.up)))
        return L10n.format(.metricsWriteFailed, String(hours), String(failure.count), failure.reason)
    }

    /// One chart point; `segment` changes at every offline sample (the line is not drawn across an outage).
    struct Point: Equatable {
        let ts: Date
        let value: Int
        let segment: Int
    }

    static func points(_ series: [MetricPoint], _ value: KeyPath<MetricPoint, Int?>) -> [Point] {
        var segment = 0
        var result: [Point] = []
        for point in series {
            // Every value of the series is kept (as before); an offline sample only starts a new line.
            if !point.online { segment += 1 }
            if let number = point[keyPath: value] { result.append(Point(ts: point.ts, value: number, segment: segment)) }
        }
        return result
    }

    /// A run of offline samples: from the first offline sample to the next online one (or `now`).
    struct OfflineRange: Equatable {
        let start: Date
        let end: Date
    }

    static func offlineRanges(_ series: [MetricPoint], now: Date) -> [OfflineRange] {
        var ranges: [OfflineRange] = []
        var start: Date?
        for point in series {
            if !point.online {
                if start == nil { start = point.ts }
            } else if let open = start {
                ranges.append(OfflineRange(start: open, end: point.ts))
                start = nil
            }
        }
        if let open = start { ranges.append(OfflineRange(start: open, end: max(now, open))) }
        return ranges
    }

    /// Uptime chip: ≥ 95 % green, ≥ 50 % orange, below red (always with the percentage as text).
    static func uptimeChip(_ uptime: Double) -> (symbol: String, text: String, tone: ChipTone) {
        let text = L10n.format(.metricsUptime, MetricsText.percent(uptime))
        if uptime >= 0.95 { return ("checkmark.circle.fill", text, .green) }
        if uptime >= 0.5 { return ("exclamationmark.triangle.fill", text, .orange) }
        return ("xmark.octagon.fill", text, .red)
    }

    /// Accessibility value of a chart: point count, lowest, highest.
    static func summary(_ values: [Int]) -> String {
        guard let low = values.min(), let high = values.max() else { return L10n.text(.metricsNoData) }
        return L10n.format(.metricsA11ySummary, String(values.count), String(low), String(high))
    }
}

enum MetricsText {
    static func percent(_ fraction: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        formatter.locale = Locale(identifier: L10n.currentLanguage.rawValue)
        return formatter.string(from: NSNumber(value: fraction)) ?? String(Int(fraction * 100))
    }
}
