import SwiftUI
import SystemExtensions
import os.log

/// Host app: activates the driver extension and is the Drobo's dashboard.
/// The app must be run from /Applications for activation to succeed with SIP enabled.
///
/// With the menu bar item on, the app keeps running after its window is closed, so it works as
/// a background agent: it keeps polling the Drobo, shows its state in the menu bar and posts
/// notifications when that state changes.
@main
struct DroboHostApp: App {
    @StateObject private var dashboard = DashboardModel()
    @StateObject private var updates = UpdateChecker()
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("updateChannel") private var updateChannel = UpdateChannel.release.rawValue

    var body: some Scene {
        Window("Drobo", id: "main") {
            ContentView()
                .environmentObject(dashboard)
                .environmentObject(updates)
                .onAppear { updates.check(UpdateChannel(rawValue: updateChannel) ?? .off) }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Drobo DriverKit") { About.show() }
            }
        }

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarContent()
                .environmentObject(dashboard)
                .environmentObject(updates)
        } label: {
            Image(systemName: dashboard.menuBarSymbol)
        }

        Settings {
            PreferencesView()
                .environmentObject(dashboard)
                .environmentObject(updates)
        }
    }
}

/// Author and project links, used by the About panel and the dashboard footer.
enum About {
    static let author = "Joseph Mattiello"
    static let profileURL = URL(string: "https://github.com/JoeMatt")!
    static let projectURL = URL(string: "https://github.com/JoeMatt/drobo-driverkit")!

    static func show() {
        let credits = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        func add(_ text: String, link: URL? = nil) {
            var attributes = base
            if let link { attributes[.link] = link }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }
        add("A DriverKit driver and dashboard for the Drobo 8D.\nCreated by ")
        add(author, link: profileURL)
        add("\n\n")
        add("github.com/JoeMatt/drobo-driverkit", link: projectURL)
        add("\n\nNot affiliated with Drobo, Inc. MIT licensed.")
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Drobo DriverKit",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 \(author)",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The drop-down under the menu bar icon.
struct MenuBarContent: View {
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snapshot = dashboard.snapshot
        Text(dashboard.summaryLine)
        if snapshot.ready, let used = snapshot.usedBytes, let free = snapshot.freeBytes {
            Text("\(DashboardModel.bytes(used)) used · \(DashboardModel.bytes(free)) free")
        }
        if snapshot.isRebuilding, snapshot.relayoutCount > 0 {
            Text("Rebuilding: \(snapshot.relayoutCount) blocks left")
        }
        Divider()
        ForEach(dashboard.luns) { lun in
            Button((lun.isMounted ? "Unmount " : "Mount ") + (lun.volumeNames.first ?? DashboardModel.bytes(lun.bytes))) {
                dashboard.setMounted(!lun.isMounted, lun: lun)
            }
            .disabled(lun.bsdName == nil || dashboard.busy)
        }
        Button("Eject All") { dashboard.ejectAll() }.disabled(dashboard.volumes.isEmpty || dashboard.busy)
        Divider()
        if let url = updates.updateURL {
            Button("Update Available…") { NSWorkspace.shared.open(url) }
        }
        Button("Open Drobo Dashboard") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
        Button("About Drobo DriverKit") { About.show() }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

/// App preferences (not the Drobo's own settings).
struct PreferencesView: View {
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var updates: UpdateChecker
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("updateChannel") private var updateChannel = UpdateChannel.release.rawValue
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError = ""

    var body: some View {
        Form {
            Toggle("Show Drobo in the menu bar", isOn: $showMenuBarItem)
            Text("With this on, the app keeps running in the background after its window is closed.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    loginError = LoginItem.set(enabled) ?? ""
                    launchAtLogin = LoginItem.isEnabled
                }
            if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.red) }
            Toggle("Notify me when the Drobo's status changes", isOn: $notificationsEnabled)
                .onChange(of: notificationsEnabled) { _, enabled in
                    if enabled { Notifier.requestPermission() }
                }
            Picker("Check for updates", selection: $updateChannel) {
                ForEach(UpdateChannel.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .onChange(of: updateChannel) { _, channel in updates.check(UpdateChannel(rawValue: channel) ?? .off) }
            HStack {
                Button("Check Now") { updates.check(UpdateChannel(rawValue: updateChannel) ?? .off) }
                    .disabled(updateChannel == UpdateChannel.off.rawValue)
                if let url = updates.updateURL {
                    Button("View Update") { NSWorkspace.shared.open(url) }
                }
            }
            Text(updates.status.isEmpty ? "Version \(UpdateChecker.version)" : updates.status)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Updates are not installed automatically yet: each copy of this app is built and signed by its owner. To update, pull the new source and rebuild.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Model

/// Polls the driver's published state every two seconds and runs the dashboard's actions.
final class DashboardModel: ObservableObject {
    @Published var snapshot = DroboSnapshot()
    @Published var volumes: [DroboVolume] = []
    @Published var luns: [DroboLUN] = []
    @Published var readRate: Double = 0             // bytes per second
    @Published var writeRate: Double = 0
    @Published var rebuildETA = ""
    @Published var message = ""
    @Published var pendingWritable: Set<Int> = []
    @Published var busy = false

    private var timer: Timer?
    private var lastRead: UInt64 = 0
    private var lastWrite: UInt64 = 0
    private var lastSample = Date()
    private var rebuildStart: (date: Date, count: UInt32)?
    private var writableSeeded = false
    private var awaitingCommand: (count: UInt64, name: String)?
    private var lastFlags: UInt32?
    private var wasRebuilding = false

    init() { start() }

    /// One line for the menu bar drop-down.
    var summaryLine: String {
        if !snapshot.driverPresent { return "Drobo: not connected" }
        if !snapshot.ready { return "Drobo: starting…" }
        let name = snapshot.name.isEmpty ? "Drobo" : snapshot.name
        let alerts = snapshot.statusLines.filter { !$0.hasPrefix("Status bit") }
        return "\(name): " + (alerts.first ?? "Healthy")
    }

    /// Menu bar icon: plain when healthy, badged when something needs attention.
    var menuBarSymbol: String {
        guard snapshot.ready, let flags = snapshot.statusFlags else { return "externaldrive" }
        if flags & 0x0132 != 0 { return "externaldrive.badge.xmark" }
        if snapshot.isRebuilding || flags & 0x00C4 != 0 { return "externaldrive.badge.exclamationmark" }
        return "externaldrive.fill"
    }

    private func notifyChanges(_ latest: DroboSnapshot) {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled"), let flags = latest.statusFlags else { return }
        defer { lastFlags = flags; wasRebuilding = latest.isRebuilding }
        guard let previous = lastFlags else { return }
        let added = flags & ~previous
        let name = latest.name.isEmpty ? "Drobo" : latest.name
        if added & 0x0132 != 0 || added & 0x0040 != 0 {
            let lines = latest.statusLines.filter { !$0.hasPrefix("Status bit") }
            Notifier.post(title: "\(name) needs attention", body: lines.joined(separator: ". "))
        } else if wasRebuilding, !latest.isRebuilding {
            Notifier.post(title: "\(name) finished rebuilding", body: "Data protection is complete.")
        }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate() }

    func refresh() {
        let now = Date()
        let latest = DroboMonitor.snapshot()
        let elapsed = now.timeIntervalSince(lastSample)
        if elapsed > 0.5 {
            readRate = latest.readBytes >= lastRead && lastRead != 0 ? Double(latest.readBytes - lastRead) / elapsed : 0
            writeRate = latest.writeBytes >= lastWrite ? Double(latest.writeBytes - lastWrite) / elapsed : 0
        }
        lastRead = latest.readBytes
        lastWrite = latest.writeBytes
        lastSample = now

        notifyChanges(latest)

        // Rebuild estimate from how fast the Drobo's "blocks left" counter falls. The counter
        // can also rise while the Drobo is still working out how much there is to do, which
        // restarts the estimate; and it needs several minutes of samples to mean anything.
        if latest.relayoutCount > 0 {
            if let start = rebuildStart, start.count >= latest.relayoutCount {
                let done = Double(start.count - latest.relayoutCount)
                let seconds = now.timeIntervalSince(start.date)
                if done >= 20, seconds > 300 {
                    rebuildETA = "about " + Self.duration(Double(latest.relayoutCount) / (done / seconds)) + " left"
                } else {
                    rebuildETA = "estimating time…"
                }
            } else {
                rebuildStart = (now, latest.relayoutCount)
                rebuildETA = "estimating time…"
            }
        } else {
            rebuildStart = nil
            rebuildETA = ""
        }

        // Report how the Drobo answered the last command we sent.
        if let awaiting = awaitingCommand, latest.commands >= awaiting.count {
            message = latest.lastCommandResult == 1
                ? "\(awaiting.name): the Drobo accepted the command."
                : "\(awaiting.name): the Drobo rejected the command (code \(latest.lastCommandResult))."
            awaitingCommand = nil
        }

        snapshot = latest
        volumes = DroboMonitor.volumes()
        luns = DroboMonitor.luns(latest, volumes: volumes)
        if !writableSeeded, latest.ready {
            pendingWritable = Set(luns.filter(\.writable).map(\.id))
            writableSeeded = true
        }
        if !latest.driverPresent { writableSeeded = false }
    }

    var writableChanged: Bool { pendingWritable != Set(luns.filter(\.writable).map(\.id)) }

    func ejectAll(then next: (() -> Void)? = nil) {
        message = "Ejecting…"
        DroboMonitor.ejectAll { [weak self] failures in
            guard let self else { return }
            if failures.isEmpty {
                self.message = "All Drobo volumes ejected."
                next?()
            } else {
                self.message = "Could not eject " + failures.joined(separator: ", ") + ". Close anything using them and try again."
                self.busy = false
            }
            self.refresh()
        }
    }

    func setMounted(_ mounted: Bool, lun: DroboLUN) {
        guard let bsd = lun.bsdName else { return }
        busy = true
        message = mounted ? "Mounting…" : "Unmounting…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let failure = DroboMonitor.setMounted(mounted, bsdName: bsd)
            DispatchQueue.main.async {
                self?.message = failure ?? (mounted ? "Mounted." : "Unmounted.")
                self?.busy = false
                self?.refresh()
            }
        }
    }

    /// Sends a management command and remembers to report the Drobo's answer.
    private func command(_ command: DroboCommand, argument: UInt32 = 0, name: String = "", label: String) {
        if let failure = DroboMonitor.send(command, argument: argument, name: name) {
            message = failure
        } else {
            message = "\(label): sent…"
            awaitingCommand = (snapshot.commands + 1, label)
        }
    }

    func blink() { command(.blink, label: "Blink lights") }

    func rename(to name: String) {
        command(.rename, argument: UInt32(Date().timeIntervalSince1970), name: name, label: "Rename")
    }

    /// Changes dual disk redundancy and the spin-down delay, keeping the Drobo's other flags.
    func setOptions(dualRedundancy: Bool, spinDownMinutes: Int) {
        var flags = UInt32(truncatingIfNeeded: snapshot.optionFlags) & 0xFFFC
        if dualRedundancy { flags |= 0x1 }
        if spinDownMinutes > 0 { flags |= 0x2 }
        command(.setOptions, argument: flags | UInt32(max(0, min(spinDownMinutes, 600))) << 16, label: "Settings")
    }

    /// Runs the write self-test on the first mounted volume that allows writing.
    func writeTest() {
        guard let lun = luns.first(where: { $0.writable && $0.isMounted }),
              let volume = volumes.first(where: { $0.lun == lun.id }) else {
            message = "Allow writes on a mounted volume first."
            return
        }
        busy = true
        message = "Testing writes on \(volume.name)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = DroboMonitor.writeTest(on: volume.id)
            DispatchQueue.main.async {
                self?.message = result
                self?.busy = false
            }
        }
    }

    /// Ejects everything, then asks the Drobo to flush its caches and power down.
    func shutDown() {
        busy = true
        ejectAll { [weak self] in
            self?.command(.standby, label: "Shut down")
            self?.busy = false
        }
    }

    /// Ejects everything, then tells the driver which volumes may be written. The driver
    /// re-announces the disks so macOS picks up the change.
    func applyWritable() {
        busy = true
        let mask = pendingWritable.reduce(UInt32(0)) { $0 | (1 << UInt32($1)) }
        ejectAll { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let failure = DroboMonitor.send(.setWritable, argument: mask) {
                    self.message = failure
                } else {
                    self.message = mask == 0 ? "All volumes are read-only again." : "Writing enabled. The volumes will reappear in a few seconds."
                }
                self.writableSeeded = false
                self.busy = false
                self.refresh()
            }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

// MARK: - Views

/// A titled card, the dashboard's only container style.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

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

    var body: some View {
        let snapshot = dashboard.snapshot
        VStack(alignment: .leading, spacing: 12) {
            header
            if snapshot.ready {
                overview
                HStack(alignment: .top, spacing: 12) {
                    bays
                    VStack(spacing: 12) {
                        volumes
                        tools
                    }
                }
            } else {
                Card(title: "Not connected") {
                    Text(snapshot.driverPresent
                         ? "Waiting for the Drobo to finish starting…"
                         : "No Drobo detected. Check its power and the Thunderbolt cable, and that the driver is activated below.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let url = updates.updateURL {
                HStack {
                    Label(updates.status, systemImage: "arrow.down.circle").font(.callout)
                    Button("View") { NSWorkspace.shared.open(url) }.controlSize(.small)
                }
            }
            if !dashboard.message.isEmpty {
                Text(dashboard.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            driver
            HStack(spacing: 4) {
                Text("Drobo DriverKit \(UpdateChecker.version) by")
                Link(About.author, destination: About.profileURL)
                Text("·")
                Link("Project on GitHub", destination: About.projectURL)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 760, alignment: .leading)
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

    private var writableWarning: String {
        var text = "Writing through this driver is new. Enable it only for volumes whose contents you have a copy of, and test with files you can afford to lose first. All Drobo volumes are ejected and reappear."
        if dashboard.snapshot.isRebuilding || (dashboard.snapshot.statusFlags ?? 0) & 0x40 != 0 {
            text = "The Drobo has no redundancy right now. Waiting until the rebuild finishes is safer.\n\n" + text
        }
        return text
    }

    // MARK: Header

    private var header: some View {
        let snapshot = dashboard.snapshot
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "externaldrive.fill").font(.system(size: 30)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name.isEmpty ? "Drobo 8D" : snapshot.name).font(.title2).bold()
                if snapshot.ready {
                    Text("8D · Serial \(snapshot.serial)" + (snapshot.firmware.isEmpty ? "" : " · Firmware \(snapshot.firmware)"))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if snapshot.ready { statusPill }
        }
    }

    private var statusPill: some View {
        let snapshot = dashboard.snapshot
        let flags = snapshot.statusFlags ?? 0
        let (text, color): (String, Color) =
            snapshot.statusFlags == nil ? ("Checking…", .gray)
            : flags & 0x0132 != 0 ? ("Needs attention", .red)
            : snapshot.isRebuilding ? ("Rebuilding", .orange)
            : flags & 0x00C4 != 0 ? ("Warning", .yellow)
            : ("Healthy", .green)
        return Text(text)
            .font(.callout).fontWeight(.semibold)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Overview (alerts and capacity)

    private var overview: some View {
        let snapshot = dashboard.snapshot
        let alerts = snapshot.statusLines.filter { $0 != "Healthy" && !$0.hasPrefix("Status bit") }
        return Card(title: "Overview") {
            ForEach(alerts, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if snapshot.isRebuilding {
                Text(snapshot.relayoutCount > 0
                     ? "\(snapshot.relayoutCount) blocks left, \(dashboard.rebuildETA). Do not power off the Drobo or remove a drive. Everything is slower until this finishes."
                     : "Do not power off the Drobo or remove a drive until this finishes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let used = snapshot.usedBytes, let free = snapshot.freeBytes, used + free > 0 {
                ProgressView(value: Double(used), total: Double(used + free))
                    .tint(Double(used) / Double(used + free) > 0.95 ? .red : (Double(used) / Double(used + free) > 0.85 ? .yellow : .blue))
                HStack {
                    figure("Used", DashboardModel.bytes(used))
                    figure("Free", DashboardModel.bytes(free))
                    figure("Protected capacity", DashboardModel.bytes(used + free))
                    if let dual = snapshot.dualDiskRedundancy { figure("Dual disk redundancy", dual ? "On" : "Off") }
                    if let minutes = snapshot.spinDownMinutes { figure("Drive spin-down", minutes > 0 ? "\(minutes) min" : "Off") }
                }
            }
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.body).fontWeight(.medium)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Drive bays

    private var bays: some View {
        Card(title: "Drive bays") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                ForEach(dashboard.snapshot.slots) { slot in
                    GridRow {
                        Circle().fill(color(for: slot)).frame(width: 9, height: 9)
                        Text(slot.id < 8 ? "\(slot.id + 1)" : "SSD").foregroundStyle(.secondary)
                        Text(slot.isEmpty ? "—" : DashboardModel.bytes(slot.physicalBytes))
                        Text(slot.isEmpty ? "" : slot.model).foregroundStyle(.secondary).lineLimit(1)
                        Text(slot.statusText)
                    }
                    .font(.callout)
                }
            }
            if dashboard.snapshot.slots.isEmpty {
                Text("No bay information yet.").foregroundStyle(.secondary).font(.callout)
            }
        }
        .frame(width: 400)
    }

    private func color(for slot: DroboSlot) -> Color {
        if slot.isEmpty { return .gray.opacity(0.35) }
        switch slot.statusCode & 0x0F {
        case 1, 6: return .red
        case 2, 5: return .yellow
        case 3: return .green
        case 4: return .orange
        default: return .gray
        }
    }

    // MARK: Volumes

    private var volumes: some View {
        Card(title: "Volumes") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Volume")
                    Text("")
                    Text("Allow writes")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(dashboard.luns) { lun in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lun.isMounted ? lun.volumeNames.joined(separator: ", ") : "Not mounted").lineLimit(1)
                            Text(DashboardModel.bytes(lun.bytes) + (lun.writable ? " · read/write" : " · read-only"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button(lun.isMounted ? "Unmount" : "Mount") { dashboard.setMounted(!lun.isMounted, lun: lun) }
                            .controlSize(.small)
                            .disabled(lun.bsdName == nil || dashboard.busy)
                        Toggle("Allow writes", isOn: Binding(
                            get: { dashboard.pendingWritable.contains(lun.id) },
                            set: { on in
                                if on { dashboard.pendingWritable.insert(lun.id) } else { dashboard.pendingWritable.remove(lun.id) }
                            }))
                            .toggleStyle(.checkbox).labelsHidden()
                    }
                    .font(.callout)
                }
            }
            if dashboard.luns.isEmpty {
                Text("No volumes reported.").foregroundStyle(.secondary).font(.callout)
            }
            HStack {
                Button("Eject All") { dashboard.ejectAll() }.disabled(dashboard.volumes.isEmpty)
                if dashboard.writableChanged {
                    Button("Apply Write Access…") { confirmWritable = true }
                }
            }
            .disabled(dashboard.busy)
        }
    }

    // MARK: Tools

    private var tools: some View {
        Card(title: "Tools") {
            HStack {
                Button("Blink Lights") { dashboard.blink() }
                Button("Rename…") {
                    newName = dashboard.snapshot.name
                    showRename = true
                }
                Button("Shut Down…") { confirmShutdown = true }
            }
            .disabled(dashboard.busy || !dashboard.snapshot.healthAvailable)
            HStack {
                Button("Settings…") {
                    editDual = dashboard.snapshot.dualDiskRedundancy ?? false
                    editSpin = dashboard.snapshot.spinDownMinutes ?? 0
                    showSettings = true
                }
                .disabled(dashboard.busy || dashboard.snapshot.dualDiskRedundancy == nil)
                Button("Test Writing…") { dashboard.writeTest() }
                    .disabled(dashboard.busy || !dashboard.luns.contains { $0.writable && $0.isMounted })
                    .help("Writes and reads back 64 MB on a writable volume to check the write path")
            }
        }
    }

    // MARK: Settings

    private var settingsSheet: some View {
        let snapshot = dashboard.snapshot
        let unsafe = snapshot.isRebuilding || (snapshot.statusFlags ?? 0) & 0x40 != 0
        return VStack(alignment: .leading, spacing: 14) {
            Text("Drobo Settings").font(.headline)
            Toggle("Dual disk redundancy", isOn: $editDual)
            Text("Survives two drive failures at the cost of capacity. Changing it makes the Drobo rearrange all data, which can take days.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Spin drives down after", selection: $editSpin) {
                Text("Never").tag(0)
                ForEach([5, 10, 15, 30, 60, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                if ![0, 5, 10, 15, 30, 60, 120].contains(editSpin) { Text("\(editSpin) minutes").tag(editSpin) }
            }
            if unsafe {
                Label("Settings cannot be changed while the Drobo is rebuilding or has no redundancy.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { showSettings = false }
                Button("Apply") {
                    dashboard.setOptions(dualRedundancy: editDual, spinDownMinutes: editSpin)
                    showSettings = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(unsafe)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: Driver

    private var driver: some View {
        let snapshot = dashboard.snapshot
        return DisclosureGroup(isExpanded: $showDriver) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.status)
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Activate") { model.activate() }
                    Button("Deactivate") { model.deactivate() }
                }
                .disabled(model.busy)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 14) {
                Text("Driver").fontWeight(.semibold)
                if snapshot.driverPresent {
                    Text("↓ \(DashboardModel.bytes(UInt64(dashboard.readRate)))/s")
                    Text("↑ \(DashboardModel.bytes(UInt64(dashboard.writeRate)))/s")
                    Text("\(snapshot.reads) reads · \(snapshot.writes) writes · \(snapshot.flushes) flushes · \(snapshot.errors) errors")
                } else {
                    Text("not running")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - System extension activation

final class ExtensionModel: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    /// The dext's bundle ID is always the app's bundle ID plus ".driver" (see project.yml),
    /// so changing the bundle ID prefix needs no code change.
    static let driverIdentifier = (Bundle.main.bundleIdentifier ?? "com.joemattiello.DroboDriverKit") + ".driver"

    @Published var status = "Use Activate after installing or updating the app."
    @Published var busy = false

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DroboDriverKit", category: "host")

    func activate() {
        submit(.activationRequest(forExtensionWithIdentifier: Self.driverIdentifier, queue: .main),
               label: "Activation")
    }

    func deactivate() {
        submit(.deactivationRequest(forExtensionWithIdentifier: Self.driverIdentifier, queue: .main),
               label: "Deactivation")
    }

    private func submit(_ request: OSSystemExtensionRequest, label: String) {
        busy = true
        status = "\(label) requested…"
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log.info("Replacing \(existing.bundleVersion, privacy: .public) with \(ext.bundleVersion, privacy: .public)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Waiting for approval in System Settings → General → Login Items & Extensions → Driver Extensions."
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        busy = false
        switch result {
        case .completed:
            status = "Done."
        case .willCompleteAfterReboot:
            status = "Will complete after a restart."
        @unknown default:
            status = "Finished with result \(result.rawValue)."
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        busy = false
        let nsError = error as NSError
        status = "Failed: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        log.error("System extension request failed: \(nsError, privacy: .public)")
    }
}
