import SwiftUI

/// Click to copy, with a brief "Copied" confirmation. Used for serials, models and other values
/// people paste into support tickets and spreadsheets.
private struct CopyOnClick: ViewModifier {
    let text: String
    @State private var copied = false

    func body(content: Content) -> some View {
        content
            .opacity(copied ? 0 : 1)
            .overlay(alignment: .trailing) {
                if copied {
                    Text("Copied").font(Theme.text(10.5, .medium)).foregroundStyle(Theme.emerald)
                        .fixedSize().transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                withAnimation(Theme.spring) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    withAnimation(Theme.spring) { copied = false }
                }
            }
            .help("Click to copy")
    }
}

extension View {
    func copyOnClick(_ text: String) -> some View { modifier(CopyOnClick(text: text)) }
}

/// Follows the Option key while the menu bar panel is open, like the Wi-Fi menu's extra details.
private final class OptionKeyWatcher: ObservableObject {
    @Published var held = NSEvent.modifierFlags.contains(.option)
    private var monitor: Any?
    private var forced: Bool { Demo.scenario != nil && UserDefaults.standard.bool(forKey: "demoOption") }

    func start() {
        held = forced || NSEvent.modifierFlags.contains(.option)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.held = event.modifierFlags.contains(.option)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The panel under the menu bar icon: status, capacity, a light per bay and the volumes.
/// Holding Option adds identifiers, driver counters and a line per drive.
struct MenuBarPanel: View {
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var commandLine: CommandLineTool
    @Environment(\.openWindow) private var openWindow
    @StateObject private var option = OptionKeyWatcher()

    var body: some View {
        let snapshot = dashboard.snapshot
        VStack(alignment: .leading, spacing: 12) {
            header
            if snapshot.ready {
                capacity
                bays
                volumes
                if option.held {
                    details
                    recentEvents
                }
            } else {
                Text(snapshot.driverPresent ? "Waiting for the Drobo to finish starting." : "No Drobo detected, or the driver is not running.")
                    .font(Theme.text(12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            actions
        }
        .padding(14)
        .frame(width: 330)
        .background(Backdrop())
        .preferredColorScheme(.dark)
        .animation(Theme.spring, value: option.held)
        .onAppear { option.start() }
        .onDisappear { option.stop() }
    }

    private var state: (text: String, color: Color, urgent: Bool) {
        let snapshot = dashboard.snapshot
        guard snapshot.driverPresent else { return ("Not connected", Theme.secondary, false) }
        guard snapshot.ready else { return ("Starting", Theme.secondary, false) }
        guard let flags = snapshot.statusFlags else { return ("Checking", Theme.secondary, false) }
        if flags & 0x0132 != 0 { return ("Needs attention", Theme.coral, true) }
        if snapshot.isRebuilding { return ("Rebuilding", Theme.amber, true) }
        if flags & 0x00C4 != 0 { return ("Warning", Theme.amber, false) }
        return ("Healthy", Theme.emerald, false)
    }

    private var header: some View {
        let snapshot = dashboard.snapshot
        let current = state
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name.isEmpty ? "Drobo" : snapshot.name)
                    .font(Theme.display(16, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                let alerts = snapshot.statusLines.filter { $0 != "Healthy" && !$0.hasPrefix("Status bit") }
                if let first = alerts.first {
                    Text(first).font(Theme.text(10.5)).foregroundStyle(current.color).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                LED(color: current.color, pulsing: current.urgent, size: 6)
                Text(current.text).font(Theme.text(11, .medium)).foregroundStyle(current.color)
            }
            .padding(.leading, 5).padding(.trailing, 11).padding(.vertical, 3)
            .background(Capsule().fill(current.color.opacity(0.10)))
            .overlay(Capsule().strokeBorder(current.color.opacity(0.24)))
        }
    }

    @ViewBuilder private var capacity: some View {
        let snapshot = dashboard.snapshot
        if let used = snapshot.usedBytes, let free = snapshot.freeBytes, used + free > 0 {
            let fraction = Double(used) / Double(used + free)
            let tint = fraction > Double(snapshot.redThreshold ?? 95) / 100 ? Theme.coral
                : (fraction > Double(snapshot.yellowThreshold ?? 85) / 100 ? Theme.amber : Theme.emerald)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(DashboardModel.bytes(used)) used").font(Theme.text(12, .medium)).foregroundStyle(Theme.primary)
                    Spacer()
                    Text("\(DashboardModel.bytes(free)) free · \(Int((fraction * 100).rounded()))%")
                        .font(Theme.text(11)).foregroundStyle(Theme.secondary)
                }
                CapacityBar(fraction: fraction, tint: tint).frame(height: 7)
                if snapshot.isRebuilding, snapshot.relayoutCount > 0 {
                    Text("Rebuilding: \(snapshot.relayoutCount) blocks left" + (dashboard.rebuildETA.isEmpty ? "" : ", \(dashboard.rebuildETA)"))
                        .font(Theme.text(10.5)).foregroundStyle(Theme.amber)
                }
                Text(glance).font(Theme.text(10.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
        }
    }

    private func tint(_ slot: DroboSlot) -> Color {
        if slot.isEmpty { return Color.white.opacity(0.10) }
        switch slot.statusCode & 0x0F {
        case 1, 6: return Theme.coral
        case 2, 4, 5: return Theme.amber
        case 3: return Theme.emerald
        default: return Theme.secondary
        }
    }

    private var bays: some View {
        HStack(spacing: 5) {
            ForEach(dashboard.snapshot.slots) { slot in
                VStack(spacing: 5) {
                    Capsule().fill(tint(slot)).frame(height: 6)
                        .shadow(color: slot.isEmpty ? .clear : tint(slot).opacity(0.6), radius: 4)
                    Text(slot.id < 8 ? "\(slot.id + 1)" : "SSD").font(Theme.mono(8.5)).foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity)
                .help(slot.isEmpty ? "Empty" : "\(DashboardModel.bytes(slot.physicalBytes)) \(slot.model): \(slot.statusText)")
            }
        }
    }

    private var volumes: some View {
        VStack(spacing: 2) {
            ForEach(dashboard.luns) { lun in
                HStack(spacing: 7) {
                    Image(systemName: "internaldrive").font(.system(size: 11, weight: .light))
                        .foregroundStyle(lun.isMounted ? Theme.primary : Theme.tertiary).frame(width: 14)
                    Text(lun.title)
                        .font(Theme.text(12, .medium)).foregroundStyle(lun.isMounted ? Theme.primary : Theme.secondary)
                        .lineLimit(1)
                    if lun.writable { Text("rw").font(Theme.mono(9, .medium)).foregroundStyle(Theme.amber) }
                    Spacer(minLength: 4)
                    if option.held {
                        Text(DashboardModel.bytes(lun.bytes) + (lun.bsdName.map { " · \($0)" } ?? ""))
                            .font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    } else if let volume = dashboard.volumes.first(where: { $0.lun == lun.id }), volume.availableBytes > 0 {
                        Text("\(DashboardModel.bytes(UInt64(volume.availableBytes))) free")
                            .font(Theme.text(10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    if let url = dashboard.volumes.first(where: { $0.lun == lun.id })?.id {
                        Button("Open") { close(); NSWorkspace.shared.open(url) }
                            .buttonStyle(PillButtonStyle(compact: true))
                    }
                    Button(lun.isMounted ? "Unmount" : "Mount") { dashboard.setMounted(!lun.isMounted, lun: lun) }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(lun.bsdName == nil || dashboard.busy)
                }
                .padding(.vertical, 2)
                if let fraction = dashboard.volumes.first(where: { $0.lun == lun.id })?.usedFraction {
                    MiniBar(fraction: fraction).padding(.leading, 21).padding(.bottom, 3)
                }
            }
        }
    }

    /// One line of at-a-glance facts for the basic view.
    private var glance: String {
        let snapshot = dashboard.snapshot
        var parts = ["\(snapshot.slots.filter { !$0.isEmpty }.count) drives"]
        if let dual = snapshot.dualDiskRedundancy { parts.append(dual ? "dual redundancy" : "single redundancy") }
        if let temperature = snapshot.systemTemperature { parts.append("\(temperature) °C") }
        if let uptime = snapshot.uptime, uptime > 0 { parts.append("up " + DashboardModel.duration(Double(uptime))) }
        return parts.joined(separator: " · ")
    }

    /// Shown while Option is held.
    private var details: some View {
        let snapshot = dashboard.snapshot
        return VStack(alignment: .leading, spacing: 5) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            line("Serial", snapshot.serial)
            line("Firmware", snapshot.firmware + (snapshot.firmwareBuild.isEmpty ? "" : "  (\(snapshot.firmwareBuild))"))
            line("App", "\(UpdateChecker.version) (\(String(UpdateChecker.builtCommit.prefix(7))))")
            line("Throughput", "↓ \(rate(dashboard.readRate))  ↑ \(rate(dashboard.writeRate))")
            line("Requests", "\(snapshot.reads) read · \(snapshot.writes) written")
            line("I/O errors", "\(snapshot.errors)")
            if let slowest = snapshot.latency.filter({ $0.count > 0 }).max(by: { $0.averageMicroseconds < $1.averageMicroseconds }) {
                line("Latency", String(format: "%.1f ms average at %@", Double(slowest.averageMicroseconds) / 1000, slowest.id))
            }
            if let minutes = snapshot.spinDownMinutes { line("Spin-down", minutes > 0 ? "\(minutes) min" : "off") }
            if let yellow = snapshot.yellowThreshold, let red = snapshot.redThreshold { line("Alerts at", "\(yellow)% and \(red)% full") }
            line("Details", snapshot.extendedFailed ? "refused by this Drobo" : (snapshot.extendedEnabled ? "on" : "off"))
            ForEach(snapshot.slots.filter { !$0.isEmpty }) { slot in
                HStack(spacing: 6) {
                    Circle().fill(tint(slot)).frame(width: 5, height: 5)
                    Text(slot.id < 8 ? "\(slot.id + 1)" : "S").font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary).frame(width: 10)
                    Text(DashboardModel.bytes(slot.physicalBytes)).font(Theme.mono(9.5, .medium)).foregroundStyle(Theme.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(slot.model).font(Theme.mono(9.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Spacer(minLength: 2)
                    if slot.isSolidState {
                        Text("SSD \(slot.lifeRemaining.map { "\($0)%" } ?? "")").font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary)
                    } else if let rpm = slot.rpm {
                        Text(verbatim: "\(rpm) rpm").font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary)
                    }
                    if let errors = slot.errorCount, errors > 0 {
                        Text("\(errors) err").font(Theme.mono(9.5)).foregroundStyle(Theme.amber)
                    }
                    if let temperature = slot.temperature {
                        Text("\(temperature)°").font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary)
                    }
                    Text(slot.statusText).font(Theme.mono(9.5)).foregroundStyle(tint(slot)).fixedSize()
                }
                .copyOnClick(slot.serial.isEmpty ? slot.model : "\(slot.model) \(slot.serial)")
            }
        }
        .transition(.opacity)
    }

    /// The last few events, with their times. Shown while Option is held.
    @ViewBuilder private var recentEvents: some View {
        let recent = dashboard.events.events.prefix(3)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ForEach(Array(recent)) { event in
                    HStack(spacing: 6) {
                        Text(event.date.formatted(date: .omitted, time: .shortened))
                            .font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary).frame(width: 58, alignment: .leading)
                        Text(event.title).font(Theme.text(10.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.text(10.5)).foregroundStyle(Theme.tertiary).frame(width: 66, alignment: .leading)
            Text(value).font(Theme.mono(10)).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .copyOnClick(value)
    }

    private func rate(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(max(0, value))) + "/s"
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("Open Dashboard") {
                    close()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(PillButtonStyle(kind: .primary, icon: "arrow.up.right", compact: true))
                Button("Eject All") { dashboard.ejectAll() }
                    .buttonStyle(PillButtonStyle(icon: "eject", compact: true))
                    .disabled(dashboard.volumes.isEmpty || dashboard.busy)
                Spacer()
                if let url = updates.updateURL {
                    Button("Update") { close(); NSWorkspace.shared.open(url) }
                        .buttonStyle(PillButtonStyle(icon: "arrow.down", compact: true))
                }
            }
            if option.held {
                HStack(spacing: 6) {
                    Button("Save Diagnostics…") { close(); Diagnostics.save() }
                        .buttonStyle(PillButtonStyle(compact: true))
                    Button(commandLine.actionTitle.replacingOccurrences(of: " Command Line Tool", with: " CLI")) {
                        close()
                        commandLine.performAction()
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(!commandLine.canAct)
                    Button("About") { close(); About.show() }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }
            HStack(spacing: 6) {
                SettingsLink { Text("Settings…") }
                    .buttonStyle(PillButtonStyle(compact: true))
                Button("Quit") {
                    AppDelegate.quitCompletely = true
                    NSApp.terminate(nil)
                }
                .buttonStyle(PillButtonStyle(compact: true))
                Spacer()
                Text(option.held ? "Click a value to copy it" : "Hold ⌥ for details")
                    .font(Theme.text(10)).foregroundStyle(Theme.tertiary)
            }
            if !dashboard.message.isEmpty {
                Text(dashboard.message).font(Theme.text(10.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Closes the panel before an action that opens something else.
    private func close() {
        NSApp.keyWindow?.close()
    }
}
