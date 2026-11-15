import SwiftUI
import SystemExtensions
import os.log

/// Host app: activates the driver extension and shows what the Drobo reports.
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

/// Polls the driver's published state every two seconds.
final class DashboardModel: ObservableObject {
    @Published var snapshot = DroboSnapshot()
    @Published var volumes: [DroboVolume] = []
    @Published var readRate: Double = 0             // bytes per second
    @Published var rebuildETA: String = ""
    @Published var ejectMessage: String = ""

    private var timer: Timer?
    private var lastBytes: UInt64 = 0
    private var lastSample = Date()
    private var rebuildStart: (date: Date, count: UInt32)?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate() }

    func refresh() {
        let now = Date()
        let latest = DroboMonitor.snapshot()
        let elapsed = now.timeIntervalSince(lastSample)
        if elapsed > 0.5, latest.readBytes >= lastBytes, lastBytes != 0 {
            readRate = Double(latest.readBytes - lastBytes) / elapsed
        } else if latest.readBytes < lastBytes {
            readRate = 0                                // driver restarted
        }
        lastBytes = latest.readBytes
        lastSample = now

        // Rebuild estimate from how fast the Drobo's "blocks left" counter falls.
        if latest.relayoutCount > 0 {
            if let start = rebuildStart, start.count >= latest.relayoutCount {
                let done = Double(start.count - latest.relayoutCount)
                let seconds = now.timeIntervalSince(start.date)
                if done > 0, seconds > 60 {
                    let remaining = Double(latest.relayoutCount) / (done / seconds)
                    rebuildETA = "about " + Self.duration(remaining) + " left"
                } else {
                    rebuildETA = "estimating…"
                }
            } else {
                rebuildStart = (now, latest.relayoutCount)
                rebuildETA = "estimating…"
            }
        } else {
            rebuildStart = nil
            rebuildETA = ""
        }

        snapshot = latest
        volumes = DroboMonitor.volumes()
    }

    func ejectAll() {
        ejectMessage = "Ejecting…"
        DroboMonitor.ejectAll { [weak self] failures in
            self?.ejectMessage = failures.isEmpty
                ? "All Drobo volumes ejected. Safe to unplug the cable."
                : "Could not eject: " + failures.joined(separator: ", ") + ". Close anything using them and try again."
            self?.refresh()
        }
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }
}

struct ContentView: View {
    @StateObject private var model = ExtensionModel()
    @StateObject private var dashboard = DashboardModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if dashboard.snapshot.ready {
                health
                Divider()
                bays
                Divider()
                volumes
            } else {
                Text(dashboard.snapshot.driverPresent
                     ? "Waiting for the Drobo to finish starting…"
                     : "No Drobo detected. Check power and the Thunderbolt cable, and that the driver is activated.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            driver
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .onAppear { dashboard.start() }
        .onDisappear { dashboard.stop() }
    }

    private var header: some View {
        let snapshot = dashboard.snapshot
        return VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.name.isEmpty ? "Drobo 8D" : snapshot.name).font(.title2).bold()
            if snapshot.ready {
                Text("Serial \(snapshot.serial)" + (snapshot.firmware.isEmpty ? "" : " · Firmware \(snapshot.firmware)"))
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var health: some View {
        let snapshot = dashboard.snapshot
        return VStack(alignment: .leading, spacing: 6) {
            Text("Status").font(.headline)
            if snapshot.statusFlags == nil {
                Text(snapshot.healthAvailable ? "Reading status from the Drobo…" : "The Drobo did not answer status queries.")
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.statusLines.filter { !$0.hasPrefix("Status bit") }, id: \.self) { line in
                Label(line, systemImage: line == "Healthy" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(line == "Healthy" ? Color.green : Color.orange)
            }
            if snapshot.isRebuilding {
                Text("Rebuilding: \(snapshot.relayoutCount) blocks left, \(dashboard.rebuildETA). Do not power off the Drobo or remove a drive. Reads are slow until this finishes.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let used = snapshot.usedBytes, let free = snapshot.freeBytes, used + free > 0 {
                ProgressView(value: Double(used), total: Double(used + free))
                Text("\(DashboardModel.bytes(used)) used · \(DashboardModel.bytes(free)) free of \(DashboardModel.bytes(used + free)) protected capacity")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var bays: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drive bays").font(.headline)
            ForEach(dashboard.snapshot.slots) { slot in
                HStack {
                    Circle().fill(color(for: slot)).frame(width: 10, height: 10)
                    Text(slot.id < 8 ? "Bay \(slot.id + 1)" : "mSATA").frame(width: 50, alignment: .leading)
                    Text(slot.isEmpty ? "—" : DashboardModel.bytes(slot.physicalBytes)).frame(width: 80, alignment: .leading)
                    Text(slot.isEmpty ? "" : slot.model).lineLimit(1).frame(width: 150, alignment: .leading)
                    Text(slot.statusText).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.callout)
            }
            if dashboard.snapshot.slots.isEmpty {
                Text("No bay information yet.").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    private var volumes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Volumes (read-only)").font(.headline)
            ForEach(dashboard.volumes) { volume in
                Text("\(volume.name) · \(DashboardModel.bytes(UInt64(max(volume.totalBytes, 0))))").font(.callout)
            }
            if dashboard.volumes.isEmpty {
                Text("No Drobo volumes are mounted.").foregroundStyle(.secondary).font(.callout)
            }
            HStack {
                Button("Eject All") { dashboard.ejectAll() }.disabled(dashboard.volumes.isEmpty)
                Text(dashboard.ejectMessage).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var driver: some View {
        let snapshot = dashboard.snapshot
        return VStack(alignment: .leading, spacing: 6) {
            Text("Driver").font(.headline)
            if snapshot.driverPresent {
                Text("\(DashboardModel.bytes(UInt64(dashboard.readRate)))/s · \(snapshot.reads) reads · \(snapshot.errors) errors · \(snapshot.rejectedWrites) writes refused")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Activate") { model.activate() }
                Button("Deactivate") { model.deactivate() }
            }
            .disabled(model.busy)
        }
    }

    private func color(for slot: DroboSlot) -> Color {
        if slot.isEmpty { return .gray.opacity(0.4) }
        switch slot.statusCode & 0x0F {
        case 1, 6: return .red
        case 2, 5: return .yellow
        case 3: return .green
        case 4: return .orange
        default: return .gray
        }
    }
}

final class ExtensionModel: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    /// The dext's bundle ID is always the app's bundle ID plus ".driver" (see project.yml),
    /// so changing the bundle ID prefix needs no code change.
    static let driverIdentifier = (Bundle.main.bundleIdentifier ?? "com.joemattiello.DroboDriverKit") + ".driver"

    @Published var status = "Not requested yet."
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
