import Carbon.HIToolbox
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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var dashboard = DashboardModel()
    @StateObject private var updates = UpdateChecker()
    @StateObject private var commandLine = CommandLineTool()
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("updateChannel") private var updateChannel = UpdateChannel.release.rawValue

    var body: some Scene {
        Window("Drobo", id: "main") {
            // Demo mode can show the menu bar panel in the window for review:
            // `-demo healthy -demoMenuPanel YES` (add `-demoOption YES` for the Option view).
            Group {
                if Demo.scenario != nil, UserDefaults.standard.bool(forKey: "demoMenuPanel") {
                    MenuBarPanel()
                } else {
                    ContentView()
                }
            }
                .environmentObject(dashboard)
                .environmentObject(updates)
                .environmentObject(commandLine)
                .onAppear { updates.check(UpdateChannel(rawValue: updateChannel) ?? .off) }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 940, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Drobo DriverKit") { About.show() }
            }
            CommandGroup(after: .appInfo) {
                Button(commandLine.actionTitle) { commandLine.performAction() }
                    .disabled(!commandLine.canAct)
                Button("Save Diagnostics…") { Diagnostics.save() }
            }
        }

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarPanel()
                .environmentObject(dashboard)
                .environmentObject(updates)
                .environmentObject(commandLine)
        } label: {
            Image(systemName: dashboard.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
                .environmentObject(dashboard)
                .environmentObject(updates)
                .environmentObject(commandLine)
        }
    }
}

/// Decides what Quit means. The first time, it asks whether to keep the Drobo in the menu bar
/// (the app keeps monitoring in the background) or to quit completely, and remembers the answer;
/// Settings can change it. "Quit Completely" in the menu bar drop-down always quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let behaviorKey = "quitBehavior"      // "" = ask, "menubar", "quit"
    static var quitCompletely = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitCompletely { return .terminateNow }
        // Log out, restart and shut down must never be held up by a question.
        if NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil { return .terminateNow }

        let defaults = UserDefaults.standard
        var behavior = defaults.string(forKey: Self.behaviorKey) ?? ""
        if behavior.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Keep Drobo in the menu bar?"
            alert.informativeText = "The app can stay in the menu bar to keep watching the Drobo and notify you when its status changes. You can change this later in Settings."
            alert.addButton(withTitle: "Keep in Menu Bar")
            alert.addButton(withTitle: "Quit Completely")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: behavior = "menubar"
            case .alertSecondButtonReturn: behavior = "quit"
            default: return .terminateCancel
            }
            defaults.set(behavior, forKey: Self.behaviorKey)
        }
        guard behavior == "menubar" else { return .terminateNow }
        defaults.set(true, forKey: "showMenuBarItem")
        for window in sender.windows where window.isVisible && window.styleMask.contains(.titled) {
            window.close()
        }
        return .terminateCancel
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

/// App preferences (not the Drobo's own settings).
struct PreferencesView: View {
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var commandLine: CommandLineTool
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("updateChannel") private var updateChannel = UpdateChannel.release.rawValue
    @AppStorage(AppDelegate.behaviorKey) private var quitBehavior = ""
    @AppStorage(Alerts.webhookKey) private var webhook = ""
    @AppStorage(VolumeIcons.automaticKey) private var automaticIcons = true
    @State private var webhookStatus = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError = ""

    var body: some View {
        Form {
            Toggle("Show Drobo in the menu bar", isOn: $showMenuBarItem)
            Text("With this on, the app keeps running in the background after its window is closed.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("When I quit the app", selection: $quitBehavior) {
                Text("Ask me").tag("")
                Text("Keep it in the menu bar").tag("menubar")
                Text("Quit completely").tag("quit")
            }
            Toggle("Give Drobo volumes a Drobo icon in Finder", isOn: $automaticIcons)
            Text("The icon shows how full the volume is. It is a small file stored on the volume, so it only appears on volumes where you have turned on Allow writes; read-only volumes keep the standard icon.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Text("Alerts cover status warnings, drive changes, I/O errors, and the Drobo disconnecting, restarting or coming back.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Also send alerts to", text: $webhook, prompt: Text("https://… (optional webhook)"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            HStack {
                Button("Send Test Alert") {
                    webhookStatus = "Sending…"
                    Alerts.send(title: "Drobo test alert", body: "Alerts from Drobo DriverKit will arrive here.", level: "info") {
                        webhookStatus = $0 ?? "Sent."
                    }
                }
                .disabled(webhook.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(webhookStatus).font(.caption).foregroundStyle(.secondary)
            }
            Text("Each alert is sent as a small JSON message to that address, so it reaches you when nobody is at this Mac. Leave it empty to keep alerts on this Mac only.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            LabeledContent("Command line tool") {
                Button(commandLine.actionTitle) { commandLine.performAction() }
                    .disabled(!commandLine.canAct)
            }
            Text("`drobo` shows the Drobo's status in a terminal, for scripts and status lines. " + commandLine.statusText)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .onAppear { commandLine.refresh() }
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

    /// History for the Events and Performance tabs. Demo mode never touches the saved log.
    let events = EventLog(persist: Demo.scenario == nil)
    let bays = BayHistory(persist: Demo.scenario == nil)
    /// The Drobo's own event log, newest first, as last read through the driver.
    @Published var droboLog: [DroboLogEntry] = []
    @Published var droboLogStatus = ""
    private var droboLogRequested = false
    private var droboLogLoadedLength = -1
    private var droboLogAutomatic = false
    private var droboLogLastCheck = Date()

    /// Re-read the Drobo's log every hour and alert on new warnings. Off until a read has worked.
    static let logAutoKey = "droboLogAutoCheck"
    /// Set once the Drobo has returned a log this app could read.
    static let logWorksKey = "droboLogReadWorks"
    /// Time of the newest log entry already seen, so only later ones alert.
    static let logSeenKey = "droboLogSeenUntil"
    static let logCheckInterval: TimeInterval = 3600
    let performance = PerformanceHistory()

    private var timer: Timer?
    private var lastRead: UInt64 = 0
    private var lastWrite: UInt64 = 0
    private var lastSample = Date()
    private var rebuildStart: (date: Date, count: UInt32)?
    private var writableSeeded = false
    private var awaitingCommand: (count: UInt64, name: String)?
    private var extendedAttempted = false

    /// The app setting behind "Read drive details". The driver forgets it when it restarts.
    static let extendedKey = "readDriveDetails"
    /// True while the Drobo is rebuilding or has no redundancy.
    static func isFragile(_ snapshot: DroboSnapshot) -> Bool {
        snapshot.isRebuilding || (snapshot.statusFlags ?? 0) & 0x40 != 0
    }

    /// Keeps the driver's optional pages in step with the app setting. One attempt per
    /// connection, so an older driver that refuses the command is not asked repeatedly.
    private func syncExtended(_ latest: DroboSnapshot) {
        guard latest.ready, latest.statusFlags != nil else { extendedAttempted = false; return }
        let wanted = UserDefaults.standard.bool(forKey: Self.extendedKey)
        if latest.extendedEnabled, !wanted {
            _ = DroboMonitor.send(.setExtended, argument: 0)
        } else if wanted, !latest.extendedEnabled, !latest.extendedFailed, !extendedAttempted {
            extendedAttempted = true
            if let failure = DroboMonitor.send(.setExtended, argument: 1) {
                message = "Drive details: " + failure
            }
        }
    }

    /// Called when the setting changes, so the next poll tries again.
    func extendedSettingChanged() {
        extendedAttempted = false
        refresh()
    }

    init() {
        events.onChanges = { Alerts.deliver($0) }
        bays.onHeadline = { [weak self] headline, advice in self?.events.add(.warning, headline, advice)
            Alerts.deliver([DroboEvent(date: Date(), level: .warning, title: headline, detail: advice)])
        }
        start()
    }

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

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate() }

    func refresh() {
        // Demo mode (see Demo.swift): made-up data, nothing read from or sent to a driver.
        if let scenario = Demo.scenario {
            let demo = Demo.data(scenario)
            snapshot = demo.snapshot
            volumes = demo.volumes
            luns = demo.luns
            readRate = demo.readRate
            writeRate = demo.writeRate
            rebuildETA = demo.rebuildETA
            if !writableSeeded {
                pendingWritable = Set(luns.filter(\.writable).map(\.id))
                writableSeeded = true
                events.seedDemo(rebuilding: scenario == "rebuilding")
                bays.seed(.demo(rebuilding: scenario == "rebuilding"))
                droboLog = DroboLog.newestFirst(DroboLog.parse(Data(DroboLog.demo.utf8)))
                droboLogStatus = "\(droboLog.count) events (demo data)"
                performance.seedDemo(rebuilding: scenario == "rebuilding")
            }
            return
        }

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

        let previous = snapshot
        let previousLUNs = luns
        snapshot = latest
        volumes = DroboMonitor.volumes()
        luns = DroboMonitor.luns(latest, volumes: volumes)
        events.observe(previous: previous, latest: latest, previousLUNs: previousLUNs, latestLUNs: luns)
        bays.record(latest, now: now)
        let thermal = bays.thermalAlerts(latest).map {
            DroboEvent(date: now, level: $0.severity == 2 ? .critical : ($0.severity == 1 ? .warning : .good), title: $0.title, detail: $0.detail)
        }
        if !thermal.isEmpty {
            for event in thermal { events.add(event.level, event.title, event.detail, date: now) }
            Alerts.deliver(thermal)
        }
        checkDroboLog(latest, now: now)
        syncDroboLog(latest)
        syncExtended(latest)
        // Keep icons this app set earlier in step with how full each volume is.
        let writableVolumes = volumes.filter { volume in luns.contains { $0.id == volume.lun && $0.writable } }.map(\.id)
        if !writableVolumes.isEmpty { MainActor.assumeIsolated { VolumeIcons.refresh(writable: writableVolumes) } }
        if latest.driverPresent {
            performance.record(date: now, readRate: readRate, writeRate: writeRate, blocksLeft: latest.relayoutCount)
        }
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

    /// Blink the lights so the unit can be told apart. Needs driver 0.27.0 or later: earlier
    /// drivers framed this command wrongly and it made the 8D hang (protocol notes 11.8, 11.14).
    func blink() {
        guard systemOperationAllowed else { return }
        command(.blink, label: "Blink lights")
    }

    /// Blink, restart and standby are only sent to a driver that frames them correctly.
    private var systemOperationAllowed: Bool {
        if snapshot.systemOperationsSafe { return true }
        message = "The running driver is older than 0.27.1 and would send this command in a form that hung the Drobo. Press Activate on the Advanced tab to load the updated driver first."
        return false
    }

    /// Asks the Drobo for its LED dim level; the answer shows up in the next poll.
    /// Asks the Drobo for its own event log. The driver reads it in the background; `syncDroboLog`
    /// picks it up when it is in.
    func readDroboLog() {
        guard Demo.scenario == nil else { return }
        guard snapshot.commandFormat >= 4 else {
            droboLogStatus = "Reading the Drobo's log needs driver 0.29.0 or later. Press Activate on the Advanced tab first."
            return
        }
        guard snapshot.eventLogState != 4 else {
            droboLogStatus = "The driver could not set up the buffer the log needs. Nothing was sent to the Drobo."
            return
        }
        guard snapshot.healthAvailable else {
            droboLogStatus = "The Drobo is not answering status requests yet."
            return
        }
        if let error = DroboMonitor.send(.readLog) {
            droboLogStatus = error
        } else {
            droboLogRequested = true
            droboLogStatus = "Reading…"
        }
    }

    /// The hourly automatic read, when it is switched on and a read has worked before.
    private func checkDroboLog(_ latest: DroboSnapshot, now: Date) {
        let defaults = UserDefaults.standard
        guard Demo.scenario == nil, defaults.bool(forKey: Self.logAutoKey), defaults.bool(forKey: Self.logWorksKey) else { return }
        guard latest.ready, latest.healthAvailable, latest.eventLogAvailable, latest.eventLogState != 1, !droboLogRequested else { return }
        guard now.timeIntervalSince(droboLogLastCheck) >= Self.logCheckInterval else { return }
        droboLogLastCheck = now
        if DroboMonitor.send(.readLog) == nil {
            droboLogRequested = true
            droboLogAutomatic = true
        }
    }

    /// Events and one alert for log entries newer than any seen before. The first log ever read
    /// only sets the mark: its entries are history, shown in the list, not news.
    private func alertOnNewLogEntries() {
        let defaults = UserDefaults.standard
        let dated = droboLog.compactMap { entry in entry.date.map { (entry: entry, date: $0) } }
        guard let newest = dated.map(\.date).max() else { return }
        let seen = defaults.double(forKey: Self.logSeenKey)
        defaults.set(newest.timeIntervalSince1970, forKey: Self.logSeenKey)
        guard seen > 0 else { return }
        let fresh = dated.filter { $0.date.timeIntervalSince1970 > seen && ($0.entry.severity >= 2 || DroboLog.critical.contains($0.entry.code)) }
        guard !fresh.isEmpty else { return }
        var produced: [DroboEvent] = []
        for item in fresh.sorted(by: { $0.date < $1.date }).suffix(8) {
            let level: DroboEvent.Level = DroboLog.critical.contains(item.entry.code) ? .critical : .warning
            let detail = "From the Drobo's own log, \(item.date.formatted(date: .abbreviated, time: .shortened))."
            events.add(level, item.entry.text, detail)
            produced.append(DroboEvent(date: Date(), level: level, title: item.entry.text, detail: detail))
        }
        Alerts.deliver(produced)
    }

    private func syncDroboLog(_ latest: DroboSnapshot) {
        if droboLogRequested, latest.eventLogState == 3 {
            droboLogRequested = false
            if droboLogAutomatic {
                // One unanswered read pauses status updates for two minutes; do not repeat it hourly.
                droboLogAutomatic = false
                UserDefaults.standard.set(false, forKey: Self.logAutoKey)
                droboLogStatus = "The Drobo did not answer the hourly log check, so hourly checks are now off. Status polling carries on."
                events.add(.warning, "Hourly Drobo log check turned off", "The Drobo did not answer one, so no more are sent until it is switched back on.")
                return
            }
            droboLogStatus = "The Drobo did not return its log. Status polling carries on; nothing else was affected."
            return
        }
        // Also picks up a log the driver already holds when the app starts.
        guard latest.eventLogState == 2, latest.eventLogLength != droboLogLoadedLength || droboLogRequested else { return }
        droboLogRequested = false
        droboLogAutomatic = false
        droboLogLastCheck = Date()
        droboLogLoadedLength = latest.eventLogLength
        guard latest.eventLogLength > 0, let data = DroboLog.fetch(length: latest.eventLogLength) else {
            droboLog = []
            droboLogStatus = "The Drobo answered with an empty log."
            return
        }
        droboLog = DroboLog.newestFirst(DroboLog.parse(data))
        droboLogStatus = droboLog.isEmpty
            ? "The Drobo answered (\(data.count) bytes) but no line was in the expected format. Save diagnostics and report it."
            : "\(droboLog.count) events, read \(Date().formatted(date: .omitted, time: .shortened))"
        if !droboLog.isEmpty {
            UserDefaults.standard.set(true, forKey: Self.logWorksKey)
            alertOnNewLogEntries()
        }
    }

    func readDimLevel() {
        guard snapshot.dimmingAvailable, snapshot.healthAvailable else { return }
        _ = DroboMonitor.send(.getDim)
    }

    /// Sets the LED dim level, 0 (brightest) to 9, then reads it back.
    func setDimLevel(_ level: Int) {
        guard snapshot.dimmingAvailable else {
            message = "LED brightness needs driver 0.28.0 or later. Press Activate on the Advanced tab first."
            return
        }
        command(.setDim, argument: UInt32(max(0, min(level, 9))), label: "LED brightness")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.readDimLevel() }
    }

    /// Ejects everything, then asks the Drobo to restart.
    func restart() {
        guard systemOperationAllowed else { return }
        busy = true
        ejectAll { [weak self] in
            self?.command(.restart, label: "Restart")
            self?.busy = false
        }
    }

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

    /// Puts the Drobo-style Finder icon on a volume, or takes it off. Writes to the volume, so
    /// only where writing is allowed.
    func setFinderIcon(_ on: Bool, lun: DroboLUN) {
        guard lun.writable, let volume = volumes.first(where: { $0.lun == lun.id }) else {
            message = "Allow writes on the volume first: its Finder icon is a file stored on the volume."
            return
        }
        let failure = MainActor.assumeIsolated { on ? VolumeIcons.apply(to: volume.id) : VolumeIcons.remove(from: volume.id) }
        message = failure ?? (on ? "Finder icon set on \(volume.name). Finder can take a moment to show it."
                                 : "Finder icon removed from \(volume.name).")
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
        guard systemOperationAllowed else { return }
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
