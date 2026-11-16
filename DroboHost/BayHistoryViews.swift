import SwiftUI

/// Drive history: what each bay has been doing over the last two weeks, and what the pattern
/// across bays suggests. See BayHistory.swift for how the conclusions are reached.
struct BayHistoryCard: View {
    @ObservedObject var history: BayHistory
    @State private var confirmClear = false

    var body: some View {
        let now = Date()
        let report = BayHistory.analyze(history.file, now: now)
        return Bezel(title: "Drive history") {
            Button("Clear") { confirmClear = true }
                .buttonStyle(PillButtonStyle(icon: "trash", compact: true))
                .disabled(history.file.changes.isEmpty)
        } content: {
            if report.bays.isEmpty {
                Text("Nothing recorded yet. Each bay's status is recorded while this app or its menu bar item is running, and kept across restarts, so a drive that is flagged and then comes back can be told apart from one that stays failed.")
                    .font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !report.headline.isEmpty { finding(report) }
                    ForEach(report.bays) { row($0, report: report, now: now) }
                    Text(footer(report))
                        .font(Theme.text(11)).foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
        return text + ". Covers only the time this app was running."
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
            Text(bay.summary).font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
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
