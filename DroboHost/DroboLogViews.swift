import SwiftUI

/// The Drobo's own event log: what the unit recorded itself, including while no computer was
/// attached. Read only when asked.
struct DroboLogCard: View {
    @ObservedObject var model: DashboardModel
    @State private var confirmRead = false
    @State private var problemsOnly = true
    @AppStorage(DashboardModel.logAutoKey) private var checkHourly = false
    @AppStorage(DashboardModel.logWorksKey) private var readWorks = false

    private var shown: [DroboLogEntry] {
        let entries = problemsOnly ? model.droboLog.filter { $0.severity > 0 || !$0.isKnown } : model.droboLog
        return Array(entries.prefix(400))
    }

    var body: some View {
        Bezel(title: "Drobo's own log") {
            Button(model.droboLog.isEmpty ? "Read from Drobo" : "Read Again") { confirmRead = true }
                .buttonStyle(PillButtonStyle(icon: "arrow.down.doc", compact: true))
                .disabled(model.busy || model.droboLogStatus == "Reading…")
                .help("Asks the Drobo for the event log it keeps itself")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if model.droboLog.isEmpty {
                    Text("The Drobo keeps its own log of power events, drive errors and rebuilds, whether or not a computer is attached. It is read only when you ask.")
                        .font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle("Problems only", isOn: $problemsOnly)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                    if shown.isEmpty {
                        Text("No warnings or notable events in the log.")
                            .font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                LED(color: color(entry), size: 6)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                Text(entry.text).font(Theme.text(12.5, entry.severity >= 2 ? .medium : .regular))
                                    .foregroundStyle(Theme.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                Spacer(minLength: 12)
                                Text(entry.date?.formatted(date: .abbreviated, time: .standard) ?? entry.stamp)
                                    .font(Theme.mono(10.5)).foregroundStyle(Theme.tertiary)
                            }
                            .padding(.vertical, 6)
                            if entry.id != shown.last?.id { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        }
                    }
                }
                if readWorks {
                    Toggle("Check every hour and alert on new warnings", isOn: $checkHourly)
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                        .help("Re-reads this log hourly. The Drobo records drive overheating, drive errors and power trouble here, including things it does not report any other way")
                }
                if !model.droboLogStatus.isEmpty {
                    Text(model.droboLogStatus)
                        .font(Theme.text(11)).foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog("Read the Drobo's event log?", isPresented: $confirmRead) {
            Button("Read Log") { model.readDroboLog() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends the request Drobo Dashboard used. It only reads, but it is a command this driver has sent to few Drobos. If the Drobo does not answer, status updates pause for two minutes and the volumes are not affected.")
        }
    }

    private func color(_ entry: DroboLogEntry) -> Color {
        guard entry.isKnown else { return Theme.tertiary }
        switch entry.severity {
        case 2: return Theme.amber
        case 1: return Theme.ice
        default: return Theme.emerald
        }
    }
}


/// What the Drobo's log adds up to: how full it has been, power trouble, rebuilds, and what was
/// logged against each bay. Nothing here is read from the Drobo; it is worked out from the log
/// already shown above.
struct DroboLogSummaryCard: View {
    let entries: [DroboLogEntry]

    var body: some View {
        let summary = DroboLogSummary.make(entries)
        return Bezel(title: "What the log shows") {
            if let first = summary.first, let last = summary.last {
                Text("\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.mono(10)).foregroundStyle(Theme.tertiary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if summary.capacity.count > 1 { capacity(summary) }
                facts(summary)
                if !summary.bays.isEmpty { bays(summary) }
            }
        }
    }

    private func capacity(_ summary: DroboLogSummary) -> some View {
        let points = summary.capacity
        let peak = points.map(\.usedPercent).max() ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("USED SPACE").font(Theme.mono(9.5, .medium)).tracking(1.2).foregroundStyle(Theme.tertiary)
                Spacer(minLength: 8)
                Text(String(format: "now %.0f%% · peak %.0f%%", points.last?.usedPercent ?? 0, peak))
                    .font(Theme.mono(10)).foregroundStyle(Theme.secondary)
            }
            PercentLine(points: points.map { ($0.date, $0.usedPercent) })
                .frame(height: 44)
        }
    }

    private func facts(_ summary: DroboLogSummary) -> some View {
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted)
        var rows: [(label: String, value: String, tint: Color)] = []
        func dated(_ label: String, _ dates: [Date]) {
            rows.append((label, dates.isEmpty ? "None" : "\(dates.count) · last \(dates.last!.formatted(day))", dates.isEmpty ? Theme.secondary : Theme.amber))
        }
        dated("Unexpected power losses", summary.powerLosses)
        dated("Internal errors", summary.internalErrors)
        rows.append(("Overheating", summary.overheating.isEmpty ? "None logged"
                     : "\(summary.overheating.count) · last \(summary.overheating.last?.date?.formatted(day) ?? "?")",
                     summary.overheating.isEmpty ? Theme.secondary : Theme.coral))
        if !summary.rebuilds.isEmpty {
            var value = "\(summary.rebuilds.count)"
            if let longest = summary.longestRebuild { value += " · longest \(DroboLogSummary.duration(longest))" }
            if summary.rebuilds.last?.end == nil { value += " · one unfinished" }
            rows.append(("Rebuilds", value, summary.rebuilds.last?.end == nil ? Theme.amber : Theme.secondary))
        }
        if let latest = summary.healthChecks.last {
            var value = "\(latest.speed) MiB/s"
            var tint = Theme.secondary
            if let trend = summary.healthTrend, trend.latest < trend.best {
                value += " · best \(trend.best)"
                if trend.latest * 2 < trend.best { tint = Theme.amber }
            }
            rows.append(("Health check speed", value, tint))
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(rows[index].label).font(Theme.text(12)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 12)
                    Text(rows[index].value).font(Theme.text(12, .medium)).foregroundStyle(rows[index].tint)
                }
                .padding(.vertical, 5)
                if index != rows.count - 1 { Rectangle().fill(Theme.hairline).frame(height: 1) }
            }
        }
    }

    private func bays(_ summary: DroboLogSummary) -> some View {
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return VStack(alignment: .leading, spacing: 6) {
            Text("BY BAY").font(Theme.mono(9.5, .medium)).tracking(1.2).foregroundStyle(Theme.tertiary)
            ForEach(summary.bays) { bay in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    LED(color: bay.problems.isEmpty ? Theme.emerald : Theme.amber, size: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(bay.name).font(Theme.text(12, .medium)).foregroundStyle(Theme.primary)
                        .frame(width: 58, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        if let drive = bay.drives.last {
                            Text("\(drive.capacity) drive since \(drive.firstSeen.formatted(day))"
                                 + (bay.drives.count > 1 ? " · \(bay.drives.count - 1) earlier" : ""))
                                .font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                        }
                        Text(bay.problems.isEmpty ? "Nothing logged against it"
                             : "\(bay.problemText) · last \(bay.problems.first?.date?.formatted(day) ?? "?")")
                            .font(Theme.text(11.5)).foregroundStyle(bay.problems.isEmpty ? Theme.tertiary : Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// A 0 to 100 % series over its own time span, filled underneath.
struct PercentLine: View {
    let points: [(date: Date, value: Double)]

    var body: some View {
        Canvas { context, size in
            guard let first = points.first?.date, let last = points.last?.date, points.count > 1 else { return }
            let total = max(1, last.timeIntervalSince(first))
            func place(_ point: (date: Date, value: Double)) -> CGPoint {
                CGPoint(x: CGFloat(point.date.timeIntervalSince(first) / total) * size.width,
                        y: CGFloat(1 - min(1, max(0, point.value / 100))) * (size.height - 2) + 1)
            }
            for mark in [0.25, 0.5, 0.75] {
                var guide = Path()
                guide.move(to: CGPoint(x: 0, y: size.height * mark))
                guide.addLine(to: CGPoint(x: size.width, y: size.height * mark))
                context.stroke(guide, with: .color(Color.white.opacity(0.05)), lineWidth: 0.5)
            }
            var line = Path()
            line.move(to: place(points[0]))
            for point in points.dropFirst() { line.addLine(to: place(point)) }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [Theme.ice.opacity(0.22), Theme.ice.opacity(0.0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(Theme.ice.opacity(0.9)), lineWidth: 1.2)
        }
        .accessibilityHidden(true)
    }
}
