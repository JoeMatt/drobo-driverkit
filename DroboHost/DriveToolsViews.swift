import SwiftUI

/// Commands of the Drobo's built-in shell, sent through the driver (protocol notes 11.22).
/// The first group only prints what the firmware knows. The others make the Drobo talk to its
/// drives or change the disk pack; each asks first, and the driver checks the Drobo's own
/// status again before it sends anything.
struct DriveToolsCard: View {
    @ObservedObject var model: DashboardModel
    @State private var bay = 0
    @State private var asking: DroboShellCommand?
    @State private var typed = ""

    private var snapshot: DroboSnapshot { model.snapshot }
    private var idle: Bool { !model.busy && snapshot.healthAvailable && snapshot.shellState != 1 && model.shellStatus != "Running…" }
    private func commands(_ kinds: [DroboShellCommand.Kind]) -> [DroboShellCommand] {
        DroboShellCommand.all.filter { kinds.contains($0.kind) }
    }
    /// What the user types to confirm a command that changes the disk pack.
    private var phrase: String { "bay \(bay + 1)" }

    var body: some View {
        Bezel(title: "Drive tools · untested") {
            VStack(alignment: .leading, spacing: 10) {
                Text("These ask the Drobo's own firmware directly. They were worked out from Drobo's software and firmware and have not been run on a Drobo yet. If the Drobo does not answer one, status updates pause for two minutes; volumes are not affected by that.")
                    .font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !snapshot.shellAvailable {
                    Text("Needs driver 0.30.0 or later. Press Activate on the Advanced tab after updating.")
                        .font(Theme.text(11.5, .medium)).foregroundStyle(Theme.amber)
                }

                group("Read the firmware's records", "Nothing is sent to the drives.") {
                    ForEach(commands([.readsMemory])) { command in
                        Button(command.title) { model.runShell(command, confirmed: false) }
                            .buttonStyle(PillButtonStyle(compact: true))
                            .disabled(!idle || !snapshot.shellAvailable)
                            .help(command.detail)
                    }
                }
                group("Ask the drives", "The Drobo sends S.M.A.R.T. commands to every drive that is ready. Leave this until your data is copied off if the array has no redundancy.") {
                    ForEach(commands([.touchesDrives])) { command in
                        Button(command.title + "…") { typed = ""; asking = command }
                            .buttonStyle(PillButtonStyle(compact: true))
                            .disabled(!idle || !snapshot.shellAvailable)
                            .help(command.detail)
                    }
                }
                group("Change one bay", "These change the disk pack and cannot be undone. Each is refused unless the Drobo's own status allows it for the bay.") {
                    Picker("Bay", selection: $bay) {
                        ForEach(0..<8, id: \.self) { Text("Bay \($0 + 1)").tag($0) }
                    }
                    .labelsHidden().frame(width: 90)
                    ForEach(commands([.powerCycle, .wipe, .expunge])) { command in
                        let refusal = model.shellAnswered || Demo.scenario != nil
                            ? command.refusal(slot: bay, snapshot: snapshot)
                            : "Run Error counters first. Its answer lists the drives by the Drobo's slot numbers (Bay 1 should be slot 0); check that before sending a command that names a slot."
                        Button(command.title + "…") { typed = ""; asking = command }
                            .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
                            .disabled(!idle || !snapshot.shellAvailable || refusal != nil)
                            .help(refusal ?? command.detail)
                    }
                }

                if !model.shellStatus.isEmpty {
                    Text(model.shellTitle.isEmpty ? model.shellStatus : "\(model.shellTitle): \(model.shellStatus)")
                        .font(Theme.text(11)).foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.shellOutput.isEmpty {
                    ScrollView([.vertical, .horizontal]) {
                        Text(model.shellOutput)
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 320)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .alert(asking.map { $0.needsBay ? "\($0.title): Bay \(bay + 1)?" : "\($0.title)?" } ?? "",
               isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
               presenting: asking) { command in
            if command.changesThePack {
                TextField("Type \"\(phrase)\" to confirm", text: $typed)
            }
            Button(command.changesThePack ? "Send to Drobo" : "Ask the Drives", role: command.changesThePack ? .destructive : nil) {
                // Checked here as well as by disabling the button: an alert's buttons cannot
                // be disabled reliably on every macOS version.
                guard !command.changesThePack || typed.trimmingCharacters(in: .whitespaces).lowercased() == phrase else {
                    model.shellStatus = "Not sent: the confirmation text did not match."
                    return
                }
                model.runShell(command, slot: command.needsBay ? bay : 0, confirmed: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { command in
            Text(message(for: command))
        }
    }

    private func message(for command: DroboShellCommand) -> String {
        let sent = command.text.replacingOccurrences(of: "<slot>", with: "\(bay)")
        var lines = [command.detail, "Sends \"\(sent)\" to the Drobo's firmware. This command has not been tried on a Drobo from this app."]
        if command.needsBay {
            lines.append("The Drobo counts bays from 0, so Bay \(bay + 1) should be its slot \(bay). That numbering was read out of the firmware and has not been confirmed on a Drobo: compare the Error counters answer with your bays before going on.")
        }
        switch command.kind {
        case .wipe:
            lines.append("Afterwards the Drobo should treat the drive as a new, empty one and rebuild onto it. Whether it accepts a drive it gave up on before is not known. Do not do this before everything you need is copied off the Drobo.")
        case .expunge:
            lines.append("There is no command to take this back.")
        case .powerCycle:
            lines.append("Whether the Drobo counts a restart like this towards giving up on the drive is not known.")
        default:
            break
        }
        return lines.joined(separator: "\n\n")
    }

    private func group<Content: View>(_ title: String, _ note: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.text(12, .medium)).foregroundStyle(Theme.primary)
            Text(note).font(Theme.text(11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                content()
                Spacer(minLength: 0)
            }
        }
    }
}
