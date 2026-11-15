import SwiftUI
import SystemExtensions
import os.log

/// Host app: activates the driver extension and is the Drobo's dashboard.
/// The app must be run from /Applications for activation to succeed with SIP enabled.
@main
struct DroboHostApp: App {
    var body: some Scene {
        WindowGroup("Drobo") {
            ContentView()
        }
        .windowResizability(.contentSize)
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

    func start() {
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

        // Rebuild estimate from how fast the Drobo's "blocks left" counter falls.
        if latest.relayoutCount > 0 {
            if let start = rebuildStart, start.count >= latest.relayoutCount {
                let done = Double(start.count - latest.relayoutCount)
                let seconds = now.timeIntervalSince(start.date)
                if done > 0, seconds > 60 {
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

    func blink() {
        message = DroboMonitor.send(.blink) ?? "The Drobo's lights should be blinking."
    }

    func rename(to name: String) {
        let utc = UInt32(Date().timeIntervalSince1970)
        message = DroboMonitor.send(.rename, argument: utc, name: name) ?? "Name sent. It updates here within a few seconds."
    }

    /// Ejects everything, then asks the Drobo to flush its caches and power down.
    func shutDown() {
        busy = true
        ejectAll { [weak self] in
            self?.message = DroboMonitor.send(.standby) ?? "Shutdown requested. Wait for the Drobo's lights to go out before unplugging."
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
    @StateObject private var dashboard = DashboardModel()
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmShutdown = false
    @State private var confirmWritable = false
    @State private var showDriver = false

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
            if !dashboard.message.isEmpty {
                Text(dashboard.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            driver
        }
        .padding(18)
        .frame(width: 760, alignment: .leading)
        .onAppear {
            dashboard.start()
            showDriver = !dashboard.snapshot.driverPresent
        }
        .onDisappear { dashboard.stop() }
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
        }
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
                    Text("\(snapshot.reads) reads · \(snapshot.writes) writes · \(snapshot.errors) errors")
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
