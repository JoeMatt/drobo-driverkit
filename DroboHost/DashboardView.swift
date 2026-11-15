import SwiftUI

/// The dashboard window. Layout only: every action goes through `DashboardModel`, and the
/// confirmation steps in front of the risky ones (write access, shut down, settings) live here.
struct ContentView: View {
    @StateObject private var model = ExtensionModel()
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var updates: UpdateChecker
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmShutdown = false
    @State private var confirmWritable = false
    @State private var showDriver = false
    @State private var showSettings = false
    @State private var editDual = false
    @State private var editSpin = 0

    /// Tallest the dashboard may be on the current screen. The window has a hidden title bar,
    /// whose height is still added above the content, so leave room for it.
    private var maxHeight: CGFloat {
        // Demo mode can pretend the screen is small: `-demo healthy -demoMaxHeight 700`.
        let forced = UserDefaults.standard.double(forKey: "demoMaxHeight")
        if Demo.scenario != nil, forced > 0 { return forced }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        return max(420, (screen?.visibleFrame.height ?? 800) - 40)
    }

    var body: some View {
        // The window is exactly as tall as the dashboard when the screen allows it, and scrolls
        // when it does not (small displays, or a long list of alerts and volumes).
        ViewThatFits(in: .vertical) {
            panels
            ScrollView(.vertical) { panels }
        }
        .frame(width: 940)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Backdrop().ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { showDriver = !dashboard.snapshot.driverPresent }
        .alert("Rename Drobo", isPresented: $showRename) {
            TextField("Name", text: $newName)
            Button("Rename") { dashboard.rename(to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Shut down the Drobo?", isPresented: $confirmShutdown) {
            Button("Eject All and Shut Down") { dashboard.shutDown() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All Drobo volumes are ejected first, then the Drobo flushes its caches and powers down.")
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .confirmationDialog("Change which volumes can be written?", isPresented: $confirmWritable) {
            Button("Eject All and Apply") { dashboard.applyWritable() }
            Button("Cancel", role: .cancel) { dashboard.refresh() }
        } message: {
            Text(writableWarning)
        }
    }

    private var panels: some View {
        let snapshot = dashboard.snapshot
        return VStack(alignment: .leading, spacing: 10) {
            header.rise(0)
            if snapshot.ready {
                HStack(alignment: .top, spacing: 12) {
                    capacity
                    protection.frame(width: 300)
                }
                .fixedSize(horizontal: false, vertical: true)
                .rise(1)
                HStack(alignment: .top, spacing: 12) {
                    bays
                    volumes.frame(width: 350)
                }
                .fixedSize(horizontal: false, vertical: true)
                .rise(2)
                tools.rise(3)
            } else {
                offline.rise(1)
            }
            driver.rise(4)
            footer.rise(5)
        }
        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 14)
        .frame(width: 940, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var writableWarning: String {
        var text = "Writing through this driver is new. Enable it only for volumes whose contents you have a copy of, and test with files you can afford to lose first. All Drobo volumes are ejected and reappear."
        if dashboard.snapshot.isRebuilding || (dashboard.snapshot.statusFlags ?? 0) & 0x40 != 0 {
            text = "The Drobo has no redundancy right now. Waiting until the rebuild finishes is safer.\n\n" + text
        }
        return text
    }

    /// Overall state, shared by the header pill and the protection card.
    private var health: (text: String, color: Color, urgent: Bool) {
        let snapshot = dashboard.snapshot
        let flags = snapshot.statusFlags ?? 0
        if snapshot.statusFlags == nil { return ("Checking", Theme.secondary, false) }
        if flags & 0x0132 != 0 { return ("Needs attention", Theme.coral, true) }
        if snapshot.isRebuilding { return ("Rebuilding", Theme.amber, true) }
        if flags & 0x00C4 != 0 { return ("Warning", Theme.amber, false) }
        return ("Healthy", Theme.emerald, false)
    }

    private var alerts: [String] {
        dashboard.snapshot.statusLines.filter { $0 != "Healthy" && !$0.hasPrefix("Status bit") }
    }

    // MARK: Header

    private var header: some View {
        let snapshot = dashboard.snapshot
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Eyebrow(text: "Drobo 8D · Thunderbolt")
                    if Demo.scenario != nil { Eyebrow(text: "Demo data", tint: Theme.amber) }
                }
                Text(snapshot.name.isEmpty ? "Drobo 8D" : snapshot.name)
                    .font(Theme.display(34, .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if snapshot.ready {
                    Text("SERIAL \(snapshot.serial)" + (snapshot.firmware.isEmpty ? "" : "   FIRMWARE \(snapshot.firmware)"))
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if snapshot.ready { statusPill }
        }
        .padding(.horizontal, 6).padding(.bottom, 8)
    }

    private var statusPill: some View {
        let state = health
        return HStack(spacing: 6) {
            LED(color: state.color, pulsing: state.urgent, size: 7)
            Text(state.text).font(Theme.text(12.5, .medium)).foregroundStyle(state.color)
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 5)
        .background(Capsule().fill(state.color.opacity(0.10)))
        .overlay(Capsule().strokeBorder(state.color.opacity(0.24)))
        .animation(Theme.spring, value: state.text)
    }

    // MARK: Capacity

    private var capacity: some View {
        let snapshot = dashboard.snapshot
        return Bezel(title: "Capacity") {
            if let used = snapshot.usedBytes, let free = snapshot.freeBytes, used + free > 0 {
                let fraction = Double(used) / Double(used + free)
                let tint = fraction > 0.95 ? Theme.coral : (fraction > 0.85 ? Theme.amber : Theme.emerald)
                let figure = split(used)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(figure.value).font(Theme.display(46, .medium)).foregroundStyle(Theme.primary)
                    Text(figure.unit).font(Theme.display(17, .medium)).foregroundStyle(Theme.secondary)
                    Text("used").font(Theme.text(13)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Theme.mono(13, .medium)).foregroundStyle(tint)
                }
                CapacityBar(fraction: fraction, tint: tint)
                HStack(spacing: 0) {
                    stat("Free", DashboardModel.bytes(free))
                    stat("Protected capacity", DashboardModel.bytes(used + free))
                    stat("Drives", "\(snapshot.slots.filter { !$0.isEmpty }.count) of \(snapshot.slots.count)")
                }
                .padding(.top, 2)
            } else {
                Text("The Drobo has not reported its capacity yet.")
                    .font(Theme.text(13)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func split(_ bytes: UInt64) -> (value: String, unit: String) {
        let parts = DashboardModel.bytes(bytes).split(separator: " ")
        return (String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : "")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Theme.text(14, .medium)).foregroundStyle(Theme.primary)
            Text(label).font(Theme.text(11)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Protection

    private var protection: some View {
        let snapshot = dashboard.snapshot
        let state = health
        return Bezel(title: "Protection") {
            VStack(alignment: .leading, spacing: 10) {
                if let dual = snapshot.dualDiskRedundancy {
                    row("shield.lefthalf.filled", "Redundancy", dual ? "Dual disk" : "Single disk")
                }
                if let minutes = snapshot.spinDownMinutes {
                    row("moon", "Drive spin-down", minutes > 0 ? "\(minutes) min" : "Off")
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if alerts.isEmpty && !snapshot.isRebuilding {
                    Label("All data is protected.", systemImage: "checkmark.circle")
                        .font(Theme.text(12.5)).foregroundStyle(Theme.emerald)
                }
                ForEach(alerts, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle")
                        .font(Theme.text(12.5)).foregroundStyle(state.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.isRebuilding {
                    if snapshot.relayoutCount > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(snapshot.relayoutCount)").font(Theme.mono(15, .medium)).foregroundStyle(Theme.primary)
                            Text("blocks left · \(dashboard.rebuildETA)").font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                        }
                    }
                    Text("Do not power off the Drobo or remove a drive. Everything is slower until this finishes.")
                        .font(Theme.text(11.5)).foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 13, weight: .light)).foregroundStyle(Theme.secondary).frame(width: 18)
            Text(label).font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
            Spacer()
            Text(value).font(Theme.text(12.5, .medium)).foregroundStyle(Theme.primary)
        }
    }

    // MARK: Drive bays

    private var bays: some View {
        Bezel(title: "Drive bays") {
            if dashboard.snapshot.slots.isEmpty {
                Text("No bay information yet.").font(Theme.text(13)).foregroundStyle(Theme.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                    ForEach(dashboard.snapshot.slots) { bay($0) }
                }
            }
        }
    }

    private func bay(_ slot: DroboSlot) -> some View {
        let tint = color(for: slot)
        let plate = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 10) {
            Text(slot.id < 8 ? String(format: "%02d", slot.id + 1) : "SSD")
                .font(Theme.mono(10, .medium)).foregroundStyle(Theme.tertiary)
                .frame(width: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.isEmpty ? "Empty" : DashboardModel.bytes(slot.physicalBytes))
                    .font(Theme.text(13, .medium)).foregroundStyle(Theme.primary)
                Text(slot.isEmpty ? "No drive" : slot.model)
                    .font(Theme.text(10.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !slot.isEmpty {
                Text(slot.statusText).font(Theme.text(10.5, .medium)).foregroundStyle(tint).lineLimit(1)
            }
            LED(color: tint, lit: !slot.isEmpty, pulsing: slot.statusCode & 0x0F == 4 && !slot.isEmpty, size: 7)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(plate.fill(Color.white.opacity(slot.isEmpty ? 0.012 : 0.04)))
        .overlay(plate.strokeBorder(Color.white.opacity(0.07),
                                    style: StrokeStyle(lineWidth: 1, dash: slot.isEmpty ? [3, 3] : [])))
        .opacity(slot.isEmpty ? 0.62 : 1)
    }

    private func color(for slot: DroboSlot) -> Color {
        if slot.isEmpty { return Color.white.opacity(0.2) }
        switch slot.statusCode & 0x0F {
        case 1, 6: return Theme.coral
        case 2, 5, 4: return Theme.amber
        case 3: return Theme.emerald
        default: return Theme.secondary
        }
    }

    // MARK: Volumes

    private var volumes: some View {
        Bezel(title: "Volumes") {
            Text("ALLOW WRITES").font(Theme.text(9, .medium)).tracking(1.4).foregroundStyle(Theme.tertiary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(dashboard.luns) { lun in
                    HStack(spacing: 10) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 14, weight: .light))
                            .foregroundStyle(lun.isMounted ? Theme.primary : Theme.tertiary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lun.isMounted ? lun.volumeNames.joined(separator: ", ") : "Not mounted")
                                .font(Theme.text(13, .medium))
                                .foregroundStyle(lun.isMounted ? Theme.primary : Theme.secondary).lineLimit(1)
                            Text(DashboardModel.bytes(lun.bytes) + (lun.writable ? " · read/write" : " · read-only"))
                                .font(Theme.text(10.5)).foregroundStyle(lun.writable ? Theme.amber : Theme.tertiary)
                        }
                        Spacer(minLength: 4)
                        Button(lun.isMounted ? "Unmount" : "Mount") { dashboard.setMounted(!lun.isMounted, lun: lun) }
                            .buttonStyle(PillButtonStyle(compact: true))
                            .disabled(lun.bsdName == nil || dashboard.busy)
                        Toggle("Allow writes", isOn: Binding(
                            get: { dashboard.pendingWritable.contains(lun.id) },
                            set: { on in
                                if on { dashboard.pendingWritable.insert(lun.id) } else { dashboard.pendingWritable.remove(lun.id) }
                            }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Theme.amber)
                    }
                    .padding(.vertical, 7)
                    if lun.id != dashboard.luns.last?.id { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
                if dashboard.luns.isEmpty {
                    Text("No volumes reported.").font(Theme.text(13)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 10)
                HStack(spacing: 8) {
                    Button("Eject All") { dashboard.ejectAll() }
                        .buttonStyle(PillButtonStyle(icon: "eject"))
                        .disabled(dashboard.volumes.isEmpty)
                    if dashboard.writableChanged {
                        Button("Apply Write Access…") { confirmWritable = true }
                            .buttonStyle(PillButtonStyle(kind: .primary, icon: "arrow.up.right"))
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .disabled(dashboard.busy)
                .animation(Theme.spring, value: dashboard.writableChanged)
            }
        }
    }

    // MARK: Tools

    private var tools: some View {
        let unavailable = dashboard.busy || !dashboard.snapshot.healthAvailable
        return Bezel(title: "Tools") {
            HStack(spacing: 8) {
                Button("Blink Lights") { dashboard.blink() }
                    .buttonStyle(PillButtonStyle(icon: "light.max")).disabled(unavailable)
                Button("Rename…") {
                    newName = dashboard.snapshot.name
                    showRename = true
                }
                .buttonStyle(PillButtonStyle(icon: "pencil")).disabled(unavailable)
                Button("Settings…") {
                    editDual = dashboard.snapshot.dualDiskRedundancy ?? false
                    editSpin = dashboard.snapshot.spinDownMinutes ?? 0
                    showSettings = true
                }
                .buttonStyle(PillButtonStyle(icon: "slider.horizontal.3"))
                .disabled(dashboard.busy || dashboard.snapshot.dualDiskRedundancy == nil)
                Button("Test Writing…") { dashboard.writeTest() }
                    .buttonStyle(PillButtonStyle(icon: "checkmark.seal"))
                    .disabled(dashboard.busy || !dashboard.luns.contains { $0.writable && $0.isMounted })
                    .help("Writes and reads back 64 MB on a writable volume to check the write path")
                Spacer()
                Button("Shut Down…") { confirmShutdown = true }
                    .buttonStyle(PillButtonStyle(kind: .danger, icon: "power")).disabled(unavailable)
            }
            if !dashboard.message.isEmpty {
                Text(dashboard.message).font(Theme.text(12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(Theme.spring, value: dashboard.message)
    }

    // MARK: Not connected

    private var offline: some View {
        let present = dashboard.snapshot.driverPresent
        return Bezel(title: present ? "Starting" : "Not connected") {
            VStack(alignment: .leading, spacing: 10) {
                Text(present ? "Waiting for the Drobo." : "No Drobo detected.")
                    .font(Theme.display(24, .medium)).foregroundStyle(Theme.primary)
                Text(present
                     ? "The driver is loaded and the Drobo is still finishing its start-up."
                     : "Check its power and the Thunderbolt cable, and that the driver is activated below.")
                    .font(Theme.text(13)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !dashboard.message.isEmpty {
                    Text(dashboard.message).font(Theme.text(12)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.vertical, 18)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Settings

    private var settingsSheet: some View {
        let snapshot = dashboard.snapshot
        let unsafe = snapshot.isRebuilding || (snapshot.statusFlags ?? 0) & 0x40 != 0
        return VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Drobo settings")
            Toggle("Dual disk redundancy", isOn: $editDual).toggleStyle(.switch).tint(Theme.emerald)
            Text("Survives two drive failures at the cost of capacity. Changing it makes the Drobo rearrange all data, which can take days.")
                .font(Theme.text(11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Spin drives down after", selection: $editSpin) {
                Text("Never").tag(0)
                ForEach([5, 10, 15, 30, 60, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                if ![0, 5, 10, 15, 30, 60, 120].contains(editSpin) { Text("\(editSpin) minutes").tag(editSpin) }
            }
            if unsafe {
                Label("Settings cannot be changed while the Drobo is rebuilding or has no redundancy.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.amber).font(Theme.text(12)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { showSettings = false }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    dashboard.setOptions(dualRedundancy: editDual, spinDownMinutes: editSpin)
                    showSettings = false
                }
                .buttonStyle(PillButtonStyle(kind: .primary, icon: "arrow.up.right"))
                .keyboardShortcut(.defaultAction)
                .disabled(unsafe)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 400)
        .background(Backdrop())
        .preferredColorScheme(.dark)
    }

    // MARK: Driver

    private var driver: some View {
        let snapshot = dashboard.snapshot
        let plate = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.spring) { showDriver.toggle() }
            } label: {
                HStack(spacing: 14) {
                    Eyebrow(text: "Driver")
                    if snapshot.driverPresent {
                        rate("arrow.down", dashboard.readRate, Theme.emerald)
                        rate("arrow.up", dashboard.writeRate, Theme.ice)
                        Text("\(snapshot.reads) reads · \(snapshot.writes) writes · \(snapshot.flushes) flushes · \(snapshot.errors) errors")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(snapshot.errors > 0 ? Theme.coral : Theme.tertiary)
                            .lineLimit(1)
                    } else {
                        Text("Not running").font(Theme.text(12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if let url = updates.updateURL {
                        Button("Update available") { NSWorkspace.shared.open(url) }
                            .buttonStyle(PillButtonStyle(icon: "arrow.down", compact: true))
                            .help(updates.status)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .regular)).foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(showDriver ? 180 : 0))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showDriver {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.status)
                        .font(Theme.text(12)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Activate") { model.activate() }
                            .buttonStyle(PillButtonStyle(kind: .primary, icon: "arrow.up.right"))
                        Button("Deactivate") { model.deactivate() }
                            .buttonStyle(PillButtonStyle())
                    }
                    .disabled(model.busy)
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(plate.fill(Color.white.opacity(0.03)))
        .overlay(plate.strokeBorder(Color.white.opacity(0.06)))
    }

    private static let rateFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private func rate(_ symbol: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .regular)).foregroundStyle(tint)
            Text(Self.rateFormatter.string(fromByteCount: Int64(max(0, value))) + "/s")
                .font(Theme.mono(11, .medium)).foregroundStyle(Theme.primary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 5) {
            Text("Drobo DriverKit \(UpdateChecker.version) by")
            Link(About.author, destination: About.profileURL)
            Text("·")
            Link("Project on GitHub", destination: About.projectURL)
        }
        .font(Theme.text(10.5))
        .foregroundStyle(Theme.tertiary)
        .tint(Theme.secondary)
        .padding(.horizontal, 6).padding(.top, 2)
    }
}
