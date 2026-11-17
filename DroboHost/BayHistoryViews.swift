import SwiftUI

/// Drive history: what each bay has been doing over the last two weeks, and what the pattern
/// across bays suggests. See BayHistory.swift for how the conclusions are reached.
struct BayHistoryCard: View {
    @ObservedObject var history: BayHistory
    @State private var confirmClear = false
    /// Closed, the card shows only what the history adds up to; the per-bay timelines open on request.
    @AppStorage("driveHistoryExpanded") private var expanded = false

    var body: some View {
        let now = Date()
        let report = BayHistory.analyze(history.file, now: now)
        return Bezel(title: "Drive history") {
            if expanded {
                Button("Clear") { confirmClear = true }
                    .buttonStyle(PillButtonStyle(icon: "trash", compact: true))
                    .disabled(history.file.changes.isEmpty)
            }
            if !report.bays.isEmpty {
                Button(expanded ? "Hide Bays" : "Show Bays") { withAnimation(Theme.spring) { expanded.toggle() } }
                    .buttonStyle(PillButtonStyle(icon: expanded ? "chevron.up" : "chevron.down", compact: true))
                    .help("Each bay's timeline over the last two weeks")
            }
        } content: {
            if report.bays.isEmpty {
                Text("Nothing recorded yet. Each bay's status is recorded while this app or its menu bar item is running, and kept across restarts, so a drive that is flagged and then comes back can be told apart from one that stays failed.")
                    .font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !report.headline.isEmpty { finding(report) }
                    if !report.heatNote.isEmpty { heat(report) }
                    if expanded {
                        ForEach(report.bays) { row($0, report: report, now: now) }
                        if !report.enclosureTemperatures.isEmpty { enclosure(report, now: now) }
                        Text(footer(report))
                            .font(Theme.text(11)).foregroundStyle(Theme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if report.headline.isEmpty && report.heatNote.isEmpty {
                        Text("No pattern of drive problems in the last \(Int(report.window / 86_400)) days.")
                            .font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .confirmationDialog("Clear the drive history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { history.clear() }
        } message: {
            Text("The conclusions above are drawn from this history and start again from nothing.")
        }
    }

    private func footer(_ report: BayReport) -> String {
        let days = Int(report.window / 86_400)
        let restarts = report.restarts.count
        var text = "Last \(days) days. "
        text += restarts == 0 ? "No Drobo restarts seen" : "\(restarts) Drobo restart\(restarts == 1 ? "" : "s") seen (white marks)"
        if let since = report.since { text += ". Recording since \(since.formatted(date: .abbreviated, time: .shortened))" }
        if report.bays.contains(where: { !$0.temperatures.isEmpty }) {
            text += ". The line under each bay is its drive temperature"
        } else if !report.enclosureTemperatures.isEmpty {
            text += ". This Drobo does not report drive temperatures, only the enclosure's"
        }
        return text + ". Covers only the time this app was running."
    }

    private func heat(_ report: BayReport) -> some View {
        let tint = report.heatSuspected ? Theme.amber : Theme.ice
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: report.heatSuspected ? "thermometer.high" : "thermometer.medium")
                .font(.system(size: 12, weight: .light)).foregroundStyle(tint)
            Text(report.heatNote).font(Theme.text(12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.20), lineWidth: 1))
    }

    private func enclosure(_ report: BayReport, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("ENCLOSURE").font(Theme.mono(9.5, .medium)).tracking(1.2).foregroundStyle(Theme.tertiary)
                Spacer(minLength: 8)
                if let low = report.enclosureLow, let high = report.enclosureHigh {
                    Text(low == high ? "\(low) °C" : "\(low)–\(high) °C").font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                }
            }
            TemperatureLine(points: report.enclosureTemperatures, start: now.addingTimeInterval(-report.window), end: now)
                .frame(height: 18)
        }
        .padding(.vertical, 4)
    }

    private func finding(_ report: BayReport) -> some View {
        let tint = report.enclosureSuspected ? Theme.amber : Theme.coral
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: report.enclosureSuspected ? "bolt.trianglebadge.exclamationmark" : "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .light)).foregroundStyle(tint)
                Text(report.headline).font(Theme.text(13, .medium)).foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(report.advice).font(Theme.text(12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 1))
    }

    static func color(_ code: UInt8) -> Color {
        guard code != 0x80 else { return Color.white.opacity(0.10) }
        switch code & 0x0F {
        case 3: return Theme.emerald
        case 1, 6: return Theme.coral
        case 2, 4, 5: return Theme.amber
        default: return Color.white.opacity(0.22)
        }
    }

    private func verdictColor(_ verdict: BayVerdict) -> Color {
        switch verdict {
        case .steady: return Theme.emerald
        case .intermittent, .flagged: return Theme.amber
        case .persistent: return Theme.coral
        case .empty: return Theme.tertiary
        }
    }

    private func row(_ bay: BayAnalysis, report: BayReport, now: Date) -> some View {
        let tint = verdictColor(bay.verdict)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(bay.name.uppercased()).font(Theme.mono(9.5, .medium)).tracking(1.2).foregroundStyle(Theme.tertiary)
                    .frame(width: 58, alignment: .leading)
                Text(bay.model.isEmpty ? "No drive" : bay.model).font(Theme.text(12, .medium)).foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(bay.verdict.label.uppercased()).font(Theme.mono(9, .medium)).tracking(1.0).foregroundStyle(tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(tint.opacity(0.12)))
            }
            BayTimeline(spans: bay.spans, restarts: report.restarts, start: now.addingTimeInterval(-report.window), end: now)
                .frame(height: 8)
            if bay.temperatures.count > 1 {
                TemperatureLine(points: bay.temperatures, start: now.addingTimeInterval(-report.window), end: now)
                    .frame(height: 18)
            }
            Text(bay.temperatureText.isEmpty ? bay.summary : bay.summary + " " + bay.temperatureText + ".")
                .font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

/// One bay's status over the window as a coloured strip, with a white mark at each Drobo restart.
struct BayTimeline: View {
    let spans: [(date: Date, statusCode: UInt8)]
    let restarts: [Date]
    let start: Date
    let end: Date

    var body: some View {
        Canvas { context, size in
            let total = max(1, end.timeIntervalSince(start))
            func x(_ date: Date) -> CGFloat { CGFloat(min(1, max(0, date.timeIntervalSince(start) / total))) * size.width }
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(track, with: .color(Color.white.opacity(0.05)))
            context.clip(to: track)
            for (index, span) in spans.enumerated() {
                let from = x(span.date)
                let until = index + 1 < spans.count ? x(spans[index + 1].date) : size.width
                // A flagged stretch is drawn at least a few points wide so a short one stays visible.
                let width = max(until - from, BayHistory.isFault(span.statusCode) ? 3 : 0.5)
                let rect = CGRect(x: from, y: 0, width: width, height: size.height)
                context.fill(Path(rect), with: .color(BayHistoryCard.color(span.statusCode).opacity(0.85)))
            }
            for restart in restarts {
                let rect = CGRect(x: x(restart) - 0.75, y: 0, width: 1.5, height: size.height)
                context.fill(Path(rect), with: .color(Color.white.opacity(0.9)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Temperature over the same window as the status strip above it. The scale is fixed
/// (20 to 60 °C) so bays can be compared by eye; the part at or above the hot mark is amber.
struct TemperatureLine: View {
    let points: [(date: Date, value: Int)]
    let start: Date
    let end: Date

    private let low = 20.0
    private let high = 60.0

    var body: some View {
        Canvas { context, size in
            let total = max(1, end.timeIntervalSince(start))
            func x(_ date: Date) -> CGFloat { CGFloat(min(1, max(0, date.timeIntervalSince(start) / total))) * size.width }
            func y(_ value: Double) -> CGFloat { CGFloat(1 - min(1, max(0, (value - low) / (high - low)))) * (size.height - 2) + 1 }
            let mark = y(Double(BayHistory.hotDrive))
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: mark))
            guide.addLine(to: CGPoint(x: size.width, y: mark))
            context.stroke(guide, with: .color(Theme.amber.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            // Break the line where nothing was recorded for a while (app closed or Drobo off).
            var previous: (date: Date, value: Int)?
            for point in points {
                if let last = previous, point.date.timeIntervalSince(last.date) < 3 * 3600 {
                    var segment = Path()
                    segment.move(to: CGPoint(x: x(last.date), y: y(Double(last.value))))
                    segment.addLine(to: CGPoint(x: x(point.date), y: y(Double(point.value))))
                    let hot = max(last.value, point.value) >= BayHistory.hotDrive
                    context.stroke(segment, with: .color((hot ? Theme.amber : Theme.ice).opacity(0.9)), lineWidth: 1.2)
                } else {
                    let dot = CGRect(x: x(point.date) - 0.75, y: y(Double(point.value)) - 0.75, width: 1.5, height: 1.5)
                    context.fill(Path(ellipseIn: dot), with: .color(Theme.ice.opacity(0.9)))
                }
                previous = point
            }
        }
        .accessibilityHidden(true)
    }
}
