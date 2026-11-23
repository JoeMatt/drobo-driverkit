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
    /// Request counters and timing, and the firmware queries: for chasing a problem, not for
    /// everyday use, so they stay out of sight until asked for.
    @AppStorage("showTroubleshooting") private var troubleshooting = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmShutdown = false
    @State private var confirmRestart = false
    @State private var confirmWritable = false
    @State private var showSettings = false
    @State private var editDual = false
    @State private var editSpin = 0
    @State private var editDim = 0.0
    @Namespace private var tabSelection

    /// The window opens at one size for every tab, so switching tabs never resizes it, and can
    /// be resized freely; a tab taller than the window scrolls.
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
                        case .events:
                            VStack(spacing: 14) {
                                if !dashboard.droboLog.isEmpty { DroboLogSummaryCard(entries: dashboard.droboLog) }
                                DroboLogCard(model: dashboard)
                                EventsTab(log: dashboard.events)
                            }
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
        .frame(minWidth: 860, idealWidth: 940, maxWidth: .infinity,
               minHeight: 480, idealHeight: 760, maxHeight: .infinity, alignment: .topLeading)
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
            Text("All Drobo volumes are ejected first, then the Drobo is asked to flush its caches and go to standby. This needs driver 0.27.0 or later and has not been verified on hardware yet. If the Drobo is rebuilding, leave it running.")
        }
        .confirmationDialog("Restart the Drobo?", isPresented: $confirmRestart) {
            Button("Eject All and Restart") { dashboard.restart() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All Drobo volumes are ejected first, then the Drobo is asked to restart. It takes several minutes to come back. This needs driver 0.27.0 or later and has not been verified on hardware yet. If the Drobo is rebuilding, leave it running.")
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: Binding(get: { dashboard.speedTest != nil }, set: { if !$0 { dashboard.closeSpeedTest() } })) {
            SpeedTestSheet(model: dashboard)
        }
        .sheet(item: $dashboard.formatRequest) { lun in
            FormatVolumeSheet(lun: lun, cancel: { dashboard.formatRequest = nil },
                              confirm: { name, fileSystem in dashboard.format(lun, name: name, fileSystem: fileSystem) })
        }
        .sheet(item: $dashboard.volumeRequest) { request in
            VolumeConfirmSheet(request: request, snapshot: dashboard.snapshot, luns: dashboard.luns,
                               cancel: { dashboard.volumeRequest = nil },
                               confirm: { action, serial in dashboard.confirmVolume(action, typedSerial: serial) })
        }
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
                            Text(lun.title)
                                .font(Theme.text(12.5, .medium))
                                .foregroundStyle(lun.isMounted ? Theme.primary : Theme.secondary).lineLimit(1)
                            if lun.writable { Text("read/write").font(Theme.text(10.5)).foregroundStyle(Theme.amber).lineLimit(1) }
                            Spacer(minLength: 4)
                            if let volume = dashboard.volumes.first(where: { $0.lun == lun.id }), let fraction = volume.usedFraction {
                                MiniBar(fraction: fraction).frame(width: 70)
                                Text("\(DashboardModel.bytes(UInt64(max(0, volume.availableBytes)))) free")
                                    .font(Theme.text(10.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                                    .frame(width: 84, alignment: .trailing)
                            } else {
                                Text(DashboardModel.bytes(lun.bytes)).font(Theme.text(10.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                            }
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
                } else if snapshot.extendedEnabled, snapshot.systemTemperature != nil {
                    row("fan", "Fans", "Not reported by this Drobo")
                }
                if let yellow = snapshot.yellowThreshold, let red = snapshot.redThreshold {
                    row("gauge.with.dots.needle.33percent", "Capacity alerts", "\(yellow)% and \(red)%")
                }
                // Drobo's software shows the cache as active when the SSD bay holds a good drive.
                if let ssd = snapshot.slots.first(where: { $0.id == 8 }) {
                    row("memorychip", "SSD cache drive", ssd.isEmpty ? "None installed" : (ssd.statusCode & 0x0F == 3 ? "Installed, healthy" : ssd.statusText))
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
        // The bays first; the history under them shows its conclusion and opens for the detail.
        VStack(spacing: 14) {
            drivesCard
            BayHistoryCard(history: dashboard.bays)
        }
    }

    private var drivesCard: some View {
        Bezel(title: "Drives") {
            Button("Blink Lights") { dashboard.blink() }
                .buttonStyle(PillButtonStyle(icon: "light.max", compact: true))
                .disabled(dashboard.busy || !dashboard.snapshot.healthAvailable)
                .help("Makes the Drobo's lights blink so you can tell which unit this is")
        } content: {
            if dashboard.snapshot.slots.isEmpty {
                Text("No bay information yet.").font(Theme.text(13)).foregroundStyle(Theme.secondary)
            } else {
                // Two columns at the default width, more as the window grows.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 8)], spacing: 8) {
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
                    if slot.isSolidState { fact("Type", "SSD") } else if let rpm = slot.rpm { fact("Speed", "\(rpm) rpm") }
                    if slot.managedBytes > 0 { fact("Managed by Drobo", DashboardModel.bytes(slot.managedBytes)) }
                }
                if slot.errorCount != nil || !slot.serial.isEmpty {
                    HStack(spacing: 14) {
                        if let life = slot.lifeRemaining { fact("Life left", "\(life)%", tint: life < 20 ? Theme.amber : nil) }
                        // The pill above already says "Healthy"; the Drobo's verdict is worth a
                        // line only when it is something else.
                        if let state = slot.diskStateText, let code = slot.diskStateCode, code != 0 {
                            fact("State", state, tint: code >= 3 ? Theme.coral : Theme.amber)
                        }
                        if let errors = slot.errorCount { fact("Errors", "\(errors)", tint: errors > 0 ? Theme.amber : nil) }
                        // Not every model reports drive temperatures (the 8D does not).
                        if let temperature = slot.temperature { fact("Temp", "\(temperature) °C") }
                    }
                    HStack(spacing: 14) {
                        if !slot.firmwareRevision.isEmpty { fact("Firmware", slot.firmwareRevision) }
                        if !slot.serial.isEmpty { fact("Serial", slot.serial) }
                    }
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: dashboard.snapshot.extendedEnabled ? 112 : 78, alignment: .topLeading)
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
                            Text(lun.title)
                                .font(Theme.text(13.5, .medium))
                                .foregroundStyle(lun.isMounted ? Theme.primary : Theme.secondary).lineLimit(1)
                            Text("Unit \(lun.id) · " + DashboardModel.bytes(lun.bytes)
                                 + (lun.bsdName.map { " · \($0)" } ?? "")
                                 + (lun.writable ? " · read/write" : " · read-only"))
                                .font(Theme.text(10.5)).foregroundStyle(lun.writable ? Theme.amber : Theme.tertiary)
                            if let volume = dashboard.volumes.first(where: { $0.lun == lun.id }), let fraction = volume.usedFraction {
                                HStack(spacing: 8) {
                                    MiniBar(fraction: fraction).frame(width: 220)
                                    Text("\(DashboardModel.bytes(UInt64(max(0, volume.totalBytes - volume.availableBytes)))) used · \(DashboardModel.bytes(UInt64(max(0, volume.availableBytes)))) free · \(Int((fraction * 100).rounded()))%")
                                        .font(Theme.text(10.5)).foregroundStyle(Theme.secondary)
                                }
                                .padding(.top, 3)
                            }
                        }
                        Spacer(minLength: 4)
                        if let url = dashboard.volumes.first(where: { $0.lun == lun.id })?.id {
                            if lun.writable {
                                let hasIcon = VolumeIcons.isSet(on: url)
                                Button(hasIcon ? "Remove Icon" : "Set Icon") { dashboard.setFinderIcon(!hasIcon, lun: lun) }
                                    .buttonStyle(PillButtonStyle(icon: "photo", compact: true))
                                    .help("A Drobo-style Finder icon with a light bar showing how full the volume is. It is a file written to the volume.")
                            }
                            Button("Speed Test…") { dashboard.openSpeedTest(lun) }
                                .buttonStyle(PillButtonStyle(icon: "speedometer", compact: true))
                                .disabled(dashboard.busy)
                                .help(lun.writable ? "Measures how fast this volume writes and reads a large file."
                                                   : "Measures write and read speed. Needs Allow writes turned on for this volume.")
                            Button("Open in Finder") { NSWorkspace.shared.open(url) }
                                .buttonStyle(PillButtonStyle(icon: "folder", compact: true))
                        }
                        if lun.looksBlank {
                            Button("Format…") { dashboard.formatRequest = lun }
                                .buttonStyle(PillButtonStyle(kind: .primary, icon: "externaldrive.badge.plus", compact: true))
                                .disabled(dashboard.busy)
                                .help("Gives this new volume a name and a file system so it can be mounted and used.")
                        } else {
                            Button(lun.isMounted ? "Unmount" : "Mount") { dashboard.setMounted(!lun.isMounted, lun: lun) }
                                .buttonStyle(PillButtonStyle(compact: true))
                                .disabled(lun.bsdName == nil || dashboard.busy)
                        }
                        if lun.uniqueID != nil {
                            Button("Delete…") { dashboard.requestVolume(.delete(unit: lun.id)) }
                                .buttonStyle(PillButtonStyle(kind: .danger, icon: "trash", compact: true))
                                .disabled(dashboard.busy || !dashboard.volumes.isEmpty)
                                .help(dashboard.volumes.isEmpty
                                      ? "Deletes this volume and everything in it. Asks for the Drobo's serial number first."
                                      : "Eject every Drobo volume first.")
                        }
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
                    if dashboard.snapshot.volumeManagementAvailable {
                        Button("New Volume…") {
                            dashboard.requestVolume(.create(bytes: dashboard.snapshot.maxVolumeBytes))
                        }
                        .buttonStyle(PillButtonStyle(icon: "plus"))
                        .disabled(!dashboard.volumes.isEmpty || dashboard.snapshot.maxVolumeBytes == 0)
                        .help(dashboard.volumes.isEmpty ? "Adds a volume to the Drobo. Existing volumes are not changed."
                                                        : "Eject every Drobo volume first.")
                    }
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
                if troubleshooting { latency.frame(width: 360) }
            }
            .fixedSize(horizontal: false, vertical: true)
            driveDetailsCard
            commandLineCard
            diagnosticsCard
            troubleshootingCard
        }
    }

    private var troubleshootingCard: some View {
        Bezel(title: "Troubleshooting") {
            HStack(spacing: 12) {
                Text("Shows the driver's request counts and timing. Not needed day to day.")
                    .font(Theme.text(11.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Toggle("Show troubleshooting tools", isOn: $troubleshooting)
                    .toggleStyle(.switch).labelsHidden().tint(Theme.emerald)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
                    editDim = Double(dashboard.snapshot.dimLevel ?? 0)
                    dashboard.readDimLevel()
                    showSettings = true
                }
                .buttonStyle(PillButtonStyle(icon: "slider.horizontal.3"))
                .disabled(dashboard.busy || dashboard.snapshot.dualDiskRedundancy == nil)
                Button("Test Writing…") { dashboard.writeTest() }
                    .buttonStyle(PillButtonStyle(icon: "checkmark.seal"))
                    .disabled(dashboard.busy || !dashboard.luns.contains { $0.writable && $0.isMounted })
                    .help("Writes and reads back 64 MB on a writable volume to check the write path")
                Spacer()
                Button("Restart…") { confirmRestart = true }
                    .buttonStyle(PillButtonStyle(icon: "arrow.clockwise")).disabled(unavailable)
                Button("Shut Down…") { confirmShutdown = true }
                    .buttonStyle(PillButtonStyle(kind: .danger, icon: "power")).disabled(unavailable)
                if dashboard.snapshot.volumeManagementAvailable {
                    Button("Reset Drobo…") { dashboard.requestVolume(.reset) }
                        .buttonStyle(PillButtonStyle(kind: .danger, icon: "exclamationmark.triangle")).disabled(unavailable)
                        .help("Erases every drive in the Drobo and its settings. Asks for the Drobo's serial number first.")
                }
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
                    if troubleshooting || snapshot.errors > 0 {
                        Text("\(snapshot.reads) reads · \(snapshot.writes) writes · \(snapshot.flushes) flushes · \(snapshot.errors) errors")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(snapshot.errors > 0 ? Theme.coral : Theme.tertiary)
                    }
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
                Label("Redundancy and spin-down cannot be changed while the Drobo is rebuilding or has no redundancy.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.amber).font(Theme.text(12)).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Text("Dim lights").font(Theme.text(13))
                Slider(value: $editDim, in: 0...9, step: 1).tint(Theme.emerald)
                Text("\(Int(editDim))").font(Theme.mono(12)).foregroundStyle(Theme.secondary).frame(width: 14)
                Button("Set") { dashboard.setDimLevel(Int(editDim)) }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(!snapshot.dimmingAvailable || dashboard.busy)
            }
            Text(snapshot.dimmingAvailable
                 ? "0 is brightest, 9 is dimmest, as in Drobo's own settings." + (snapshot.dimLevel.map { " The Drobo reports level \($0) now." } ?? "")
                 : "Needs driver 0.28.0 or later (press Activate on the Advanced tab).")
                .font(Theme.text(11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                .onChange(of: snapshot.dimLevel) { _, level in if let level { editDim = Double(level) } }
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

// MARK: Volume management confirmation

/// The one place a volume is created or deleted or the Drobo reset from the app: says what
/// will happen and keeps the button off until the Drobo's serial number has been typed.
struct VolumeConfirmSheet: View {
    let request: VolumeRequest
    let snapshot: DroboSnapshot
    let luns: [DroboLUN]
    let cancel: () -> Void
    let confirm: (DroboVolumeAction, String) -> Void

    @State private var typed = ""
    @State private var sizeText = ""
    /// For a reset: the volume size to come back with, in TiB; 0 keeps the current one.
    @State private var resetSize = 0

    private var isCreate: Bool {
        if case .create = request.action { return true }
        return false
    }

    /// The action as it will be sent: for a new volume, with the size from the field.
    private var action: DroboVolumeAction? {
        if request.action == .reset, resetSize != 0, UInt64(resetSize) << 40 != snapshot.maxVolumeBytes {
            return .resetWithVolumeSize(tib: resetSize)
        }
        guard isCreate else { return request.action }
        return DroboVolumeAction.parseSize(sizeText, max: snapshot.maxVolumeBytes).map { .create(bytes: $0) }
    }

    private var sizeProblem: String? {
        guard isCreate else { return nil }
        guard let action, case .create(let bytes) = action else { return "Give a size such as 16TB, 500GB or max." }
        if snapshot.maxVolumeBytes > 0, bytes > snapshot.maxVolumeBytes {
            return "The largest volume this Drobo allows is \(DroboVolumeAction.size(snapshot.maxVolumeBytes))."
        }
        return nil
    }

    private var serial: String { snapshot.serial.trimmingCharacters(in: .whitespaces) }
    private var destructive: Bool { !isCreate }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: isCreate ? "New volume" : (request.action == .reset ? "Reset the Drobo" : "Delete a volume"))
            if isCreate {
                HStack(spacing: 10) {
                    Text("Size").font(Theme.text(13))
                    TextField("max", text: $sizeText).textFieldStyle(.roundedBorder).frame(width: 120)
                    ForEach(["2TB", "16TB", "max"], id: \.self) { preset in
                        Button(preset) { sizeText = preset }.buttonStyle(PillButtonStyle(compact: true))
                    }
                }
                Text("This is the most the volume can ever hold. A Drobo volume only takes up the space of the files in it, so it can be larger than the drives installed today.")
                    .font(Theme.text(11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Label(action.summary(snapshot, luns: luns), systemImage: destructive ? "exclamationmark.triangle.fill" : "plus.circle")
                    .foregroundStyle(destructive ? Theme.amber : Theme.primary)
                    .font(Theme.text(13)).fixedSize(horizontal: false, vertical: true)
            }
            if let sizeProblem {
                Text(sizeProblem).font(Theme.text(12)).foregroundStyle(Theme.amber)
            }
            if request.action == .reset, snapshot.commandFormat >= 7 {
                Picker("Volume size afterwards", selection: $resetSize) {
                    Text(snapshot.maxVolumeBytes > 0 ? "Keep \(snapshot.maxVolumeBytes >> 40) TB" : "Keep the current size").tag(0)
                    ForEach(DroboVolumeAction.volumeSizes.filter { UInt64($0) << 40 != snapshot.maxVolumeBytes }, id: \.self) {
                        Text("\($0) TB").tag($0)
                    }
                }
                Text("The size of the one volume the Drobo makes for itself after the reset. A Drobo volume cannot be resized without erasing it, so this is the only place to change it. Older Macs and some backup tools want 16 TB or less.")
                    .font(Theme.text(11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if request.action == .reset {
                Text("Everything on every drive goes, and the Drobo's name and settings return to their defaults. Drives the Drobo had marked as failed are erased too and put back into use; a reset does not repair a faulty drive, so replace it first. The Drobo restarts and comes back with one blank volume.")
                    .font(Theme.text(11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("Type this Drobo's serial number (\(serial)) to confirm.")
                .font(Theme.text(12)).foregroundStyle(Theme.secondary)
            TextField("Serial number", text: $typed).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }.buttonStyle(PillButtonStyle())
                Button(isCreate ? "Create Volume" : (request.action == .reset ? "Erase Everything" : "Delete Volume")) {
                    if let action { confirm(action, typed) }
                }
                .buttonStyle(PillButtonStyle(kind: destructive ? .danger : .primary))
                .disabled(action == nil || sizeProblem != nil || !DroboMonitor.serialMatches(typed, snapshot: snapshot))
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Backdrop().ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { sizeText = "max" }
    }
}

// MARK: Formatting a new volume

/// Name and format for a volume the Drobo has made but nothing has been written to yet.
struct FormatVolumeSheet: View {
    let lun: DroboLUN
    let cancel: () -> Void
    let confirm: (String, DroboMonitor.FileSystem) -> Void

    @State private var name = "Drobo"
    @State private var fileSystem = DroboMonitor.FileSystem.apfs

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Format new volume")
            Text("Unit \(lun.id), \(DroboVolumeAction.size(lun.bytes)). A new Drobo volume is empty space: it needs a name and a file system before the Mac can mount it.")
                .font(Theme.text(12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Name").font(Theme.text(13)).frame(width: 52, alignment: .leading)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            }
            Picker("Format", selection: $fileSystem) {
                ForEach(DroboMonitor.FileSystem.allCases) { Text($0.label).tag($0) }
            }
            Text("APFS suits current Macs and Time Machine. Choose Mac OS Extended if an older Mac has to read the volume. This turns on Allow writes for the volume, which is new in this driver: keep another copy of anything you store here.")
                .font(Theme.text(11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }.buttonStyle(PillButtonStyle())
                Button("Format") { confirm(name, fileSystem) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(!DroboMonitor.validVolumeName(name))
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Backdrop().ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

// MARK: Speed test

/// Write and read speed of one volume: two dials, a size choice and a Start button.
struct SpeedTestSheet: View {
    @ObservedObject var model: DashboardModel
    @State private var megabytes = 1024

    var body: some View {
        let state = model.speedTest
        let running = state?.running ?? false
        let result = state?.result
        let writing = running && state?.phase == .writing
        let reading = running && state?.phase == .reading
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "Speed test")
            Text(state?.name ?? "").font(Theme.text(17, .medium)).foregroundStyle(Theme.primary)
            HStack(spacing: 14) {
                SpeedDial(title: "WRITE", speed: writing ? state?.liveSpeed : (result?.writeSpeed ?? state?.writeSpeed),
                          active: writing, tint: Theme.coral)
                SpeedDial(title: "READ", speed: reading ? state?.liveSpeed : result?.readSpeed,
                          active: reading, tint: Theme.emerald)
            }
            MiniBar(fraction: running ? (state?.fraction ?? 0) : (result == nil ? 0 : 1))
            Group {
                if let failure = state?.failure {
                    Text(failure).foregroundStyle(Theme.amber)
                } else if state?.writable == false {
                    Text("This volume is read-only. Turn on Allow writes for it on the Volumes tab to test it.").foregroundStyle(Theme.amber)
                } else if running {
                    Text(writing ? "Writing a test file…" : "Reading it back…").foregroundStyle(Theme.secondary)
                } else if let result {
                    Text("\(DroboVolumeAction.size(UInt64(result.bytes))) written and read back, bypassing the Mac's file cache. The test file has been removed.")
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text("Writes one large file of random data to the volume, then reads it back, and removes it. Speeds are in megabytes per second. A Drobo that is rebuilding, or busy with other work, will be slower.")
                        .foregroundStyle(Theme.secondary)
                }
            }
            .font(Theme.text(12)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Picker("Test size", selection: $megabytes) {
                    Text("1 GB").tag(1024)
                    Text("5 GB").tag(5120)
                    Text("20 GB").tag(20480)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190).disabled(running)
                Spacer()
                Button("Close") { model.closeSpeedTest() }.buttonStyle(PillButtonStyle())
                if running {
                    Button("Stop") { model.stopSpeedTest() }.buttonStyle(PillButtonStyle(kind: .danger))
                } else {
                    Button(result == nil ? "Start" : "Run Again") { model.startSpeedTest(megabytes: megabytes) }
                        .buttonStyle(PillButtonStyle(kind: .primary, icon: "speedometer"))
                        .disabled(state?.writable == false)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Backdrop().ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// One half-circle dial with the speed in its middle.
private struct SpeedDial: View {
    let title: String
    let speed: Double?
    let active: Bool
    let tint: Color

    /// Full scale: above what a Drobo 8D was seen to do over Thunderbolt (about 600 MB/s reading).
    private let scale = 800.0

    var body: some View {
        let fraction = min(max((speed ?? 0) / scale, 0), 1)
        VStack(spacing: 6) {
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * fraction)
                    .stroke(tint.opacity(speed == nil ? 0 : 1), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .animation(.easeOut(duration: 0.25), value: fraction)
                VStack(spacing: 0) {
                    Text(speed.map { String(format: "%.0f", $0) } ?? "–")
                        .font(Theme.mono(34, .medium)).foregroundStyle(speed == nil ? Theme.tertiary : Theme.primary)
                        .contentTransition(.numericText())
                    Text("MB/s").font(Theme.text(10.5)).foregroundStyle(Theme.tertiary)
                }
            }
            .frame(width: 150, height: 150)
            Text(title).font(Theme.text(10, .medium)).tracking(1.6)
                .foregroundStyle(active ? tint : Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
