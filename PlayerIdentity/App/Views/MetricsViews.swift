import Charts
import SwiftUI

/// §39 server details: last 24 h uptime %, ping (ms) and player charts; "no data" for an empty series.
struct MetricsSection: View {
    let samples: [MetricSample]
    let serverID: UUID
    let now: Date

    var body: some View {
        let series = MetricsAnalysis.series(samples, serverID: serverID, now: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text(.metricsTitle)).font(.headline)
                Spacer()
                if let uptime = MetricsAnalysis.uptime(samples, serverID: serverID, now: now) {
                    Text(L10n.format(.metricsUptime, MetricsText.percent(uptime)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(uptime >= 0.95 ? Color.green : uptime >= 0.5 ? Color.orange : Color.red)
                        .accessibilityIdentifier("metricsUptime")
                }
            }
            if series.isEmpty {
                Text(L10n.text(.metricsNoData))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .accessibilityIdentifier("metricsNoData")
            } else {
                chart(L10n.text(.metricsPing), points: series.compactMap { point in point.ping.map { (point.ts, $0) } },
                      color: .blue, offline: series.filter { !$0.online }.map(\.ts))
                chart(L10n.text(.metricsPlayers), points: series.compactMap { point in point.players.map { (point.ts, $0) } },
                      color: .green, offline: [])
            }
        }
    }

    private func chart(_ title: String, points: [(Date, Int)], color: Color, offline: [Date]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value(L10n.text(.metricsTime), point.0), y: .value(title, point.1))
                        .foregroundStyle(color)
                    PointMark(x: .value(L10n.text(.metricsTime), point.0), y: .value(title, point.1))
                        .foregroundStyle(color)
                        .symbolSize(14)
                }
                ForEach(Array(offline.enumerated()), id: \.offset) { _, date in
                    RuleMark(x: .value(L10n.text(.metricsTime), date))
                        .foregroundStyle(Color.red.opacity(0.35))
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-MetricsAnalysis.dayWindow)...now)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .frame(height: 110)
            .accessibilityLabel(title)
        }
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
