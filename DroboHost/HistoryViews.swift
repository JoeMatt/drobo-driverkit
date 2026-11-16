import Charts
import SwiftUI

/// Events tab: what changed while the app was watching, newest first.
struct EventsTab: View {
    @ObservedObject var log: EventLog
    @State private var confirmClear = false

    var body: some View {
        Bezel(title: "Events") {
            Button("Clear") { confirmClear = true }
                .buttonStyle(PillButtonStyle(icon: "trash", compact: true))
                .disabled(log.events.isEmpty)
        } content: {
            if log.events.isEmpty {
                Text("Nothing recorded yet. Events appear here when the Drobo's status, a drive or a volume changes while this app or its menu bar item is running.")
                    .font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(log.events.prefix(300)) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            LED(color: color(event.level), size: 6)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title).font(Theme.text(12.5, .medium)).foregroundStyle(Theme.primary)
                                if !event.detail.isEmpty {
                                    Text(event.detail).font(Theme.text(11)).foregroundStyle(Theme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 12)
                            Text(event.date.formatted(date: .abbreviated, time: .standard))
                                .font(Theme.mono(10.5)).foregroundStyle(Theme.tertiary)
                        }
                        .padding(.vertical, 7)
                        if event.id != log.events.prefix(300).last?.id { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
                }
                Text("Recorded by this app while it is running.")
                    .font(Theme.text(10.5)).foregroundStyle(Theme.tertiary)
            }
        }
        .confirmationDialog("Clear all recorded events?", isPresented: $confirmClear) {
            Button("Clear Events", role: .destructive) { log.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func color(_ level: DroboEvent.Level) -> Color {
        switch level {
        case .info: return Theme.ice
        case .good: return Theme.emerald
        case .warning: return Theme.amber
        case .critical: return Theme.coral
        }
    }
}

/// Performance tab: throughput and rebuild progress over time.
struct PerformanceTab: View {
    enum Range: Double, CaseIterable, Identifiable {
        case fiveMinutes = 300, hour = 3600, day = 86400
        var id: Double { rawValue }
        var label: String {
            switch self {
            case .fiveMinutes: return "5 min"
            case .hour: return "1 hour"
            case .day: return "24 hours"
            }
        }
    }

    @ObservedObject var history: PerformanceHistory
    @State private var range = Range.hour

    var body: some View {
        let samples = history.samples(last: range.rawValue, now: history.recent.last?.date ?? Date())
        VStack(spacing: 10) {
            Bezel(title: "Throughput") {
                rangePicker
            } content: {
                if samples.count < 2 {
                    Text("Collecting. History builds up while this app or its menu bar item is running.")
                        .font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
                } else {
                    HStack(spacing: 0) {
                        figure("Read now", rate(samples.last?.readRate ?? 0), Theme.emerald)
                        figure("Read peak", rate(samples.map(\.readRate).max() ?? 0), Theme.emerald)
                        figure("Write now", rate(samples.last?.writeRate ?? 0), Theme.ice)
                        figure("Write peak", rate(samples.map(\.writeRate).max() ?? 0), Theme.ice)
                    }
                    Chart {
                        ForEach(samples) { sample in
                            LineMark(x: .value("Time", sample.date), y: .value("MB/s", sample.readRate / 1e6))
                                .foregroundStyle(by: .value("Direction", "Read"))
                            LineMark(x: .value("Time", sample.date), y: .value("MB/s", sample.writeRate / 1e6))
                                .foregroundStyle(by: .value("Direction", "Write"))
                        }
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                    .chartForegroundStyleScale(["Read": Theme.emerald, "Write": Theme.ice])
                    .chartLegend(.hidden)
                    .chartYAxisLabel("MB/s")
                    .dimAxes()
                    .frame(height: 170)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            let rebuild = samples.filter { $0.blocksLeft > 0 }
            if rebuild.count >= 2 {
                Bezel(title: "Rebuild") {
                    Text("\(rebuild.last?.blocksLeft ?? 0) blocks left")
                        .font(Theme.mono(11, .medium)).foregroundStyle(Theme.amber)
                } content: {
                    Chart(rebuild) { sample in
                        AreaMark(x: .value("Time", sample.date), y: .value("Blocks left", Int(sample.blocksLeft)))
                            .foregroundStyle(LinearGradient(colors: [Theme.amber.opacity(0.35), Theme.amber.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", sample.date), y: .value("Blocks left", Int(sample.blocksLeft)))
                            .foregroundStyle(Theme.amber)
                            .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .dimAxes()
                    .frame(height: 110)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 2) {
            ForEach(Range.allCases) { item in
                Button(item.label) { withAnimation(Theme.spring) { range = item } }
                    .buttonStyle(.plain)
                    .font(Theme.text(11, .medium))
                    .foregroundStyle(range == item ? Theme.primary : Theme.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(range == item ? 0.10 : 0)))
                    .contentShape(Capsule())
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private func figure(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Theme.mono(14, .medium)).foregroundStyle(Theme.primary)
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(label).font(Theme.text(11)).foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private func rate(_ value: Double) -> String {
        Self.formatter.string(fromByteCount: Int64(max(0, value))) + "/s"
    }
}

private extension View {
    /// Quiet grid lines and labels that sit back on the dark background.
    func dimAxes() -> some View {
        self
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel().foregroundStyle(Color.white.opacity(0.4)).font(.system(size: 9.5))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel().foregroundStyle(Color.white.opacity(0.4)).font(.system(size: 9.5))
                }
            }
    }
}
