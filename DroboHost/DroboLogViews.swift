import SwiftUI

/// The Drobo's own event log: what the unit recorded itself, including while no computer was
/// attached. Read only when asked.
struct DroboLogCard: View {
    @ObservedObject var model: DashboardModel
    @State private var confirmRead = false
    @State private var problemsOnly = true

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
            Text("This sends the request Drobo Dashboard used. It only reads, but it is a command this driver has sent to few Drobos. If the Drobo does not answer, status updates pause for 30 seconds and the volumes are not affected.")
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
