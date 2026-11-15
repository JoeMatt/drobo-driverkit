import SwiftUI
import SystemExtensions
import os.log

/// Minimal host app: its only job is to activate / deactivate the embedded driver extension.
/// The app must be run from /Applications for activation to succeed with SIP enabled.
@main
struct DroboHostApp: App {
    var body: some Scene {
        WindowGroup("Drobo DriverKit") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var model = ExtensionModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drobo 8D driver extension")
                .font(.headline)
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Activate") { model.activate() }
                    .keyboardShortcut(.defaultAction)
                Button("Deactivate") { model.deactivate() }
            }
            .disabled(model.busy)
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
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
