import SwiftUI

/// The dashboard window: a header, four tabs and a footer. Layout only: every action goes through
/// `DashboardModel`, and the confirmation steps in front of the risky ones (write access, shut
/// down, settings) live here.
struct ContentView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary", drives = "Drives", volumes = "Volumes"
        case events = "Events", performance = "Performance", advanced = "Advanced"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .summary: return "square.grid.2x2"
            case .drives: return "internaldrive"
            case .volumes: return "externaldrive"
            case .events: return "clock"
            case .performance: return "chart.xyaxis.line"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    @StateObject private var model = ExtensionModel()
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var commandLine: CommandLineTool
    /// Demo mode can open on a given tab: `-demo healthy -demoTab drives`.
    @State private var tab: Tab = {
        guard Demo.scenario != nil, let name = UserDefaults.standard.string(forKey: "demoTab") else { return .summary }
        return Tab(rawValue: name.capitalized) ?? .summary
    }()
    @AppStorage(DashboardModel.extendedKey) private var readDriveDetails = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmShutdown = false
    @State private var confirmWritable = false
    @State private var showSettings = false
    @State private var editDual = false
    @State private var editSpin = 0
    @Namespace private var tabSelection

    /// The window is one fixed size for every tab, so switching tabs never resizes it; a tab that
    /// is taller than the space scrolls. Capped to the screen on small displays. The hidden
    /// title bar's height is still added above the content, so leave room for it.
    private var windowHeight: CGFloat {
        // Demo mode can pretend the screen is small: `-demo healthy -demoMaxHeight 600`.
        let forced = UserDefaults.standard.double(forKey: "demoMaxHeight")
        if Demo.scenario != nil, forced > 0 { return forced }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        return min(760, max(420, (screen?.visibleFrame.height ?? 800) - 40))
    }

    var body: some View {
        let ready = dashboard.snapshot.ready
        VStack(alignment: .leading, spacing: 10) {
            header.rise(0)
            if ready { tabBar.rise(1) }
            ScrollView(.vertical) {
                Group {
                    if !ready {
                        VStack(spacing: 10) { offline; driverCard }
                    } else {
                        switch tab {
                        case .summary: summaryTab
                        case .drives: drivesTab
                        case .volumes: volumesTab
                        case .events: EventsTab(log: dashboard.events)
                        case .performance: PerformanceTab(history: dashboard.performance)
                        case .advanced: advancedTab
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .rise(2)
            footer
        }
        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
        .frame(width: 940, height: windowHeight, alignment: .topLeading)
        .background(Backdrop().ignoresSafeArea())
        .preferredColorScheme(.dark)
        .alert("Rename Drobo", isPresented: $showRename) {
            TextField("Name", text: $newName)
            Button("Rename") { dashboard.rename(to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Shut down the Drobo?", isPresented: $confirmShutdown) {
            Button("Eject All and Shut Down") { dashboard.shutDown() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All Drobo volumes are ejected first, then the Drobo is asked to flush its caches and power down. This command has not been verified on hardware, and a related one (Blink Lights) made the Drobo restart instead. If the Drobo is rebuilding, leave it running.")
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .confirmationDialog("Change which volumes can be written?", isPresented: $confirmWritable) {
            Button("Eject All and Apply") { dashboard.applyWritable() }
            Button("Cancel", role: .cancel) { dashboard.refresh() }
        } message: {
            Text(writableWarning)
        }
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

    // MARK: Header and tabs

    private var header: some View {
        let snapshot = dashboard.snapshot
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    // Nine slots (eight bays and the mSATA bay) is the 8D; anything else is another model.
                    Eyebrow(text: (snapshot.slots.isEmpty || snapshot.slots.count == 9 ? "Drobo 8D" : "Drobo") + " · Thunderbolt")
                    if Demo.scenario != nil { Eyebrow(text: "Demo data", tint: Theme.amber) }
                }
                Text(snapshot.name.isEmpty ? "Drobo" : snapshot.name)
                    .font(Theme.display(30, .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if snapshot.ready {
                    HStack(spacing: 14) {
                        Text("SERIAL \(snapshot.serial)").copyOnClick(snapshot.serial)
                        if !snapshot.firmware.isEmpty { Text("FIRMWARE \(snapshot.firmware)").copyOnClick(snapshot.firmware) }
                    }
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.tertiary)
                }
            }
            Spacer()
            if snapshot.ready { statusPill }
        }
        .padding(.horizontal, 6).padding(.bottom, 4)
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

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(Theme.spring) { tab = item }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol).font(.system(size: 12, weight: .light))
                        Text(item.rawValue).font(Theme.text(12.5, .medium))
                        if item == .drives, attentionBays > 0 { badge(attentionBays) }
                    }
                    .foregroundStyle(tab == item ? Theme.primary : Theme.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background {
                        if tab == item {
                            Capsule().fill(Color.white.opacity(0.10))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
                                .matchedGeometryEffect(id: "tab", in: tabSelection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.03)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
    }

    /// Bays whose drive is in any state other than healthy.
    private var attentionBays: Int {
        dashboard.snapshot.slots.filter { !$0.isEmpty && $0.statusCode & 0x0F != 3 }.count
    }

    private func badge(_ count: Int) -> some View {
        Text("\(count)")
            .font(Theme.mono(9.5, .medium)).foregroundStyle(Theme.amber)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Theme.amber.opacity(0.14)))
    }

    // MARK: Summary

    private var summaryTab: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                capacity
                protection.frame(width: 300)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                bayLights
                details.frame(width: 340)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var capacity: some View {
        let snapshot = dashboard.snapshot
        return Bezel(title: "Capacity") {
            if let used = snapshot.usedBytes, let free = snapshot.freeBytes, used + free > 0 {
                let fraction = Double(used) / Double(used + free)
                let red = Double(snapshot.redThreshold ?? 95) / 100
                let yellow = Double(snapshot.yellowThreshold ?? 85) / 100
                let tint = fraction > red ? Theme.coral : (fraction > yellow ? Theme.amber : Theme.emerald)
                let figure = split(used)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(figure.value).font(Theme.display(44, .medium)).foregroundStyle(Theme.primary)
                    Text(figure.unit).font(Theme.display(16, .medium)).foregroundStyle(Theme.secondary)
                    Text("used").font(Theme.text(13)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Theme.mono(13, .medium)).foregroundStyle(tint)
                }
                CapacityBar(fraction: fraction, tint: tint)
                HStack(spacing: 0) {
                    stat("Free", DashboardModel.bytes(free))
                    stat("Protected capacity", DashboardModel.bytes(used + free))
                    if let unprotected = snapshot.unprotectedBytes, unprotected > 0 {
                        stat("Unprotected", DashboardModel.bytes(unprotected))
                    }
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
                .lineLimit(1).copyOnClick(value)
        }
    }

    /// One light per bay, like the front of the unit. Opens the Drives tab.
    private var bayLights: some View {
        let slots = dashboard.snapshot.slots
        return Bezel(title: "Drives and volumes") {
            HStack(spacing: 6) {
                Button("Eject All") { dashboard.ejectAll() }
                    .buttonStyle(PillButtonStyle(icon: "eject", compact: true))
                    .disabled(dashboard.volumes.isEmpty || dashboard.busy)
                Button("All drives") { withAnimation(Theme.spring) { tab = .drives } }
                    .buttonStyle(PillButtonStyle(icon: "arrow.right", compact: true))
            }
        } content: {
            if slots.isEmpty {
                Text("No bay information yet.").font(Theme.text(13)).foregroundStyle(Theme.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(slots) { slot in
                        VStack(spacing: 7) {
                            Capsule()
                                .fill(slot.isEmpty ? Color.white.opacity(0.08) : color(for: slot))
                                .frame(height: 7)
                                .shadow(color: slot.isEmpty ? .clear : color(for: slot).opacity(0.6), radius: 5)
                            Text(slot.id < 8 ? "\(slot.id + 1)" : "SSD")
                                .font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .help(slot.isEmpty ? "Empty" : "\(DashboardModel.bytes(slot.physicalBytes)) \(slot.model): \(slot.statusText)")
                    }
                }
                .padding(.top, 4)
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(dashboard.luns) { lun in
                        HStack(spacing: 8) {
                            Image(systemName: "internaldrive")
                                .font(.system(size: 12, weight: .light))
                                .foregroundStyle(lun.isMounted ? Theme.primary : Theme.tertiary)
                                .frame(width: 16)
                            Text(lun.isMounted ? lun.volumeNames.joined(separator: ", ") : "Not mounted")
                                .font(Theme.text(12.5, .medium))
                                .foregroundStyle(lun.isMounted ? Theme.primary : Theme.secondary).lineLimit(1)
                            Text(DashboardModel.bytes(lun.bytes) + (lun.writable ? " · read/write" : ""))
                                .font(Theme.text(10.5)).foregroundStyle(lun.writable ? Theme.amber : Theme.tertiary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let url = dashboard.volumes.first(where: { $0.lun == lun.id })?.id {
                                Button("Open") { NSWorkspace.shared.open(url) }
                                    .buttonStyle(PillButtonStyle(compact: true))
                                    .help("Open in Finder")
                            }
                            Button(lun.isMounted ? "Unmount" : "Mount") { dashboard.setMounted(!lun.isMounted, lun: lun) }
                                .buttonStyle(PillButtonStyle(compact: true))
                                .disabled(lun.bsdName == nil || dashboard.busy)
                        }
                        .padding(.vertical, 4)
                    }
                    if dashboard.luns.isEmpty {
                        Text("No volumes reported.").font(Theme.text(12)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var details: some View {
        let snapshot = dashboard.snapshot
        return Bezel(title: "Details") {
            VStack(alignment: .leading, spacing: 9) {
                row("cpu", "Firmware", snapshot.firmware.isEmpty ? "Unknown" : snapshot.firmware)
                if !snapshot.firmwareBuild.isEmpty { row("calendar", "Firmware build", snapshot.firmwareBuild) }
                row("bolt.horizontal", "Interface", "Thunderbolt")
                row("number", "Serial", snapshot.serial)
                if let temperature = snapshot.systemTemperature { row("thermometer.medium", "Temperature", "\(temperature) °C") }
                if let uptime = snapshot.uptime, uptime > 0 { row("clock", "Uptime", Self.uptimeText(uptime)) }
                if !snapshot.fanLevels.isEmpty {
                    row("fan", "Fans", snapshot.fanLevels.map { "level \($0)" }.joined(separator: ", "))
                }
                if let yellow = snapshot.yellowThreshold, let red = snapshot.redThreshold {
                    row("gauge.with.dots.needle.33percent", "Capacity alerts", "\(yellow)% and \(red)%")
                }
                row("internaldrive", "Drives", "\(snapshot.slots.filter { !$0.isEmpty }.count) of \(snapshot.slots.count) bays")
                row("externaldrive.badge.checkmark", "Raw capacity", DashboardModel.bytes(snapshot.slots.reduce(0) { $0 + $1.physicalBytes }))
                if !dashboard.message.isEmpty {
                    Text(dashboard.message).font(Theme.text(11)).foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func uptimeText(_ seconds: UInt32) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour, .minute] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }

    // MARK: Drives

    private var drivesTab: some View {
        Bezel(title: "Drives") {
            EmptyView()
        } content: {
            if dashboard.snapshot.slots.isEmpty {
                Text("No bay information yet.").font(Theme.text(13)).foregroundStyle(Theme.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                    ForEach(dashboard.snapshot.slots) { drive($0) }
                }
            }
        }
    }

    private func drive(_ slot: DroboSlot) -> some View {
        let tint = color(for: slot)
        let plate = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(slot.id < 8 ? "BAY \(slot.id + 1)" : "SSD BAY")
                    .font(Theme.mono(9.5, .medium)).tracking(1.2).foregroundStyle(Theme.tertiary)
                Spacer()
                Text(slot.statusText).font(Theme.text(11, .medium)).foregroundStyle(slot.isEmpty ? Theme.tertiary : tint)
                LED(color: tint, lit: !slot.isEmpty, pulsing: slot.statusCode & 0x0F == 4 && !slot.isEmpty, size: 7)
            }
            if slot.isEmpty {
                Text("No drive").font(Theme.text(13)).foregroundStyle(Theme.tertiary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(DashboardModel.bytes(slot.physicalBytes)).font(Theme.display(19, .medium)).foregroundStyle(Theme.primary)
                    Text(slot.model).font(Theme.text(12)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).copyOnClick(slot.model)
                }
                HStack(spacing: 14) {
                    if !slot.interface.isEmpty { fact("Interface", slot.interface) }
                    if slot.managedBytes > 0 { fact("Managed by Drobo", DashboardModel.bytes(slot.managedBytes)) }
                }
                if slot.temperature != nil || slot.errorCount != nil || !slot.serial.isEmpty {
                    HStack(spacing: 14) {
                        if let temperature = slot.temperature, temperature > 0 { fact("Temp", "\(temperature) °C") }
                        if let errors = slot.errorCount { fact("Errors", "\(errors)", tint: errors > 0 ? Theme.amber : nil) }
                        if !slot.firmwareRevision.isEmpty { fact("Firmware", slot.firmwareRevision) }
                        if !slot.serial.isEmpty { fact("Serial", slot.serial) }
                    }
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: dashboard.snapshot.extendedEnabled ? 96 : 78, alignment: .topLeading)
        .background(plate.fill(Color.white.opacity(slot.isEmpty ? 0.012 : 0.04)))
        .overlay(plate.strokeBorder(Color.white.opacity(0.07),
                                    style: StrokeStyle(lineWidth: 1, dash: slot.isEmpty ? [3, 3] : [])))
        .opacity(slot.isEmpty ? 0.62 : 1)
    }

    private func fact(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            Text(label).font(Theme.text(10.5)).foregroundStyle(Theme.tertiary)
            Text(value).font(Theme.text(10.5, .medium)).foregroundStyle(tint ?? Theme.secondary)
                .lineLimit(1).copyOnClick(value)
        }
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

    private var volumesTab: some View {
        Bezel(title: "Volumes") {
            Text("ALLOW WRITES").font(Theme.text(9, .medium)).tracking(1.4).foregroundStyle(Theme.tertiary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(dashboard.luns) { lun in
                    HStack(spacing: 10) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(lun.isMounted ? Theme.primary : Theme.tertiary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lun.isMounted ? lun.volumeNames.joined(separator: ", ") : "Not mounted")
                                .font(Theme.text(13.5, .medium))
                                .foregroundStyle(lun.isMounted ? Theme.primary : Theme.secondary).lineLimit(1)
                            Text("Unit \(lun.id) · " + DashboardModel.bytes(lun.bytes)
                                 + (lun.bsdName.map { " · \($0)" } ?? "")
                                 + (lun.writable ? " · read/write" : " · read-only"))
                                .font(Theme.text(10.5)).foregroundStyle(lun.writable ? Theme.amber : Theme.tertiary)
                        }
                        Spacer(minLength: 4)
                        if let url = dashboard.volumes.first(where: { $0.lun == lun.id })?.id {
                            if lun.writable {
                                let hasIcon = VolumeIcons.isSet(on: url)
                                Button(hasIcon ? "Remove Icon" : "Set Icon") { dashboard.setFinderIcon(!hasIcon, lun: lun) }
                                    .buttonStyle(PillButtonStyle(icon: "photo", compact: true))
                                    .help("A Drobo-style Finder icon with a light bar showing how full the volume is. It is a file written to the volume.")
                            }
                            Button("Open in Finder") { NSWorkspace.shared.open(url) }
                                .buttonStyle(PillButtonStyle(icon: "folder", compact: true))
                        }
                        Button(lun.isMounted ? "Unmount" : "Mount") { dashboard.setMounted(!lun.isMounted, lun: lun) }
                            .buttonStyle(PillButtonStyle(compact: true))
                            .disabled(lun.bsdName == nil || dashboard.busy)
                        Toggle("Allow writes", isOn: Binding(
                            get: { dashboard.pendingWritable.contains(lun.id) },
                            set: { on in
                                if on { dashboard.pendingWritable.insert(lun.id) } else { dashboard.pendingWritable.remove(lun.id) }
                            }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Theme.amber)
                            .padding(.leading, 18)
                    }
                    .padding(.vertical, 9)
                    if lun.id != dashboard.luns.last?.id { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
                if dashboard.luns.isEmpty {
                    Text("No volumes reported.").font(Theme.text(13)).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 8) {
                    Button("Eject All") { dashboard.ejectAll() }
                        .buttonStyle(PillButtonStyle(icon: "eject"))
                        .disabled(dashboard.volumes.isEmpty)
                    if dashboard.writableChanged {
                        Button("Apply Write Access…") { confirmWritable = true }
                            .buttonStyle(PillButtonStyle(kind: .primary, icon: "arrow.up.right"))
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                    Spacer()
                    message
                }
                .padding(.top, 12)
                .disabled(dashboard.busy)
                .animation(Theme.spring, value: dashboard.writableChanged)
            }
        }
    }

    @ViewBuilder private var message: some View {
        if !dashboard.message.isEmpty {
            Text(dashboard.message).font(Theme.text(12)).foregroundStyle(Theme.secondary)
                .lineLimit(2).multilineTextAlignment(.trailing)
        }
    }

    // MARK: Advanced

    private var advancedTab: some View {
        VStack(spacing: 10) {
            tools
            HStack(alignment: .top, spacing: 10) {
                driverCard
                latency.frame(width: 360)
            }
            .fixedSize(horizontal: false, vertical: true)
            driveDetailsCard
            commandLineCard
            diagnosticsCard
        }
    }

    /// Opt-in for the status pages the driver does not read by default.
    private var driveDetailsCard: some View {
        let snapshot = dashboard.snapshot
        let status = snapshot.extendedFailed
            ? "This Drobo did not answer the request, so the driver stopped asking. It stays off until the driver restarts."
            : snapshot.extendedEnabled ? "On. Drive details are on the Drives tab; temperature, uptime and fans are on Summary."
            : readDriveDetails ? "Asked for; waiting for the driver. This needs driver 0.25.0 or later (press Activate after updating)."
            : "Off."
        return Bezel(title: "Drive and system details · experimental") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Asks the Drobo for each drive's temperature, error count, firmware revision and serial number, and for its own temperature, uptime, fans and power supplies. These are read-only status requests that Drobo's own software also sends, but they have not been tried on every model. A request the Drobo refuses is dropped.")
                        .font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status).font(Theme.text(11.5, .medium))
                        .foregroundStyle(snapshot.extendedFailed ? Theme.amber : Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Read drive and system details", isOn: $readDriveDetails)
                    .toggleStyle(.switch).labelsHidden().tint(Theme.emerald)
                    .onChange(of: readDriveDetails) { _, _ in dashboard.extendedSettingChanged() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var diagnosticsCard: some View {
        Bezel(title: "Diagnostics") {
            HStack(spacing: 12) {
                Text("Saves what the driver publishes, including the raw status pages, to a file for bug reports and decoder tests. The serial number and Drobo name are removed; nothing is sent to the Drobo or uploaded.")
                    .font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Save Diagnostics…") { Diagnostics.save() }
                    .buttonStyle(PillButtonStyle(icon: "square.and.arrow.down"))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tools: some View {
        let unavailable = dashboard.busy || !dashboard.snapshot.healthAvailable
        return Bezel(title: "Tools") {
            HStack(spacing: 8) {
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
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var driverCard: some View {
        let snapshot = dashboard.snapshot
        return Bezel(title: "Driver") {
            if let url = updates.updateURL {
                Button("Update available") { NSWorkspace.shared.open(url) }
                    .buttonStyle(PillButtonStyle(icon: "arrow.down", compact: true))
                    .help(updates.status)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if snapshot.driverPresent {
                    HStack(spacing: 16) {
                        rate("arrow.down", dashboard.readRate, Theme.emerald)
                        rate("arrow.up", dashboard.writeRate, Theme.ice)
                    }
                    Text("\(snapshot.reads) reads · \(snapshot.writes) writes · \(snapshot.flushes) flushes · \(snapshot.errors) errors")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(snapshot.errors > 0 ? Theme.coral : Theme.tertiary)
                } else {
                    Text("Not running").font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text(model.status)
                    .font(Theme.text(12)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Activate") { model.activate() }
                        .buttonStyle(PillButtonStyle(kind: snapshot.driverPresent ? .quiet : .primary, icon: "arrow.up.right"))
                    Button("Deactivate") { model.deactivate() }
                        .buttonStyle(PillButtonStyle())
                }
                .disabled(model.busy)
            }
        }
    }

    private static let rateFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private func rate(_ symbol: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .regular)).foregroundStyle(tint)
            Text(Self.rateFormatter.string(fromByteCount: Int64(max(0, value))) + "/s")
                .font(Theme.mono(13, .medium)).foregroundStyle(Theme.primary)
        }
    }

    /// The driver's own request timing since it started, by request size.
    private var latency: some View {
        let rows = dashboard.snapshot.latency.filter { $0.count > 0 }
        return Bezel(title: "Request latency") {
            if rows.isEmpty {
                Text("No requests timed yet.").font(Theme.text(12.5)).foregroundStyle(Theme.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Up to").gridColumnAlignment(.leading)
                        Text("Requests")
                        Text("Average")
                        Text("Slowest")
                    }
                    .font(Theme.text(10.5)).foregroundStyle(Theme.tertiary)
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.id).font(Theme.text(12.5, .medium)).foregroundStyle(Theme.primary)
                            Text("\(row.count)")
                            Text(milliseconds(row.averageMicroseconds))
                            Text(milliseconds(row.maxMicroseconds))
                        }
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.secondary)
                    }
                }
                Text("Since the driver started.").font(Theme.text(10.5)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func milliseconds(_ microseconds: UInt64) -> String {
        String(format: microseconds < 10_000 ? "%.2f ms" : "%.0f ms", Double(microseconds) / 1000)
    }

    private var commandLineCard: some View {
        Bezel(title: "Command line") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("drobo").font(Theme.mono(13, .medium)).foregroundStyle(Theme.primary)
                    Text("Read-only status for terminals, scripts and status lines. " + commandLine.statusText)
                        .font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(commandLine.actionTitle.replacingOccurrences(of: " Command Line Tool", with: "")) {
                    commandLine.performAction()
                }
                .buttonStyle(PillButtonStyle(icon: "terminal"))
                .disabled(!commandLine.canAct)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { commandLine.refresh() }
    }

    // MARK: Not connected

    private var offline: some View {
        let present = dashboard.snapshot.driverPresent
        return Bezel(title: present ? "Starting" : "Not connected") {
            VStack(alignment: .leading, spacing: 10) {
                Text(present ? "Waiting for the Drobo." : "No Drobo detected.")
                    .font(Theme.display(24, .medium)).foregroundStyle(Theme.primary)
                Text(present
                     ? "The driver is loaded and the Drobo is still finishing its start-up. This can take several minutes."
                     : "Check its power and the Thunderbolt cable, and that the driver is activated below.")
                    .font(Theme.text(13)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !dashboard.message.isEmpty {
                    Text(dashboard.message).font(Theme.text(12)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.vertical, 14)
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
        .padding(.horizontal, 6)
    }
}
