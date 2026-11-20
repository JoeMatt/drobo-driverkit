import Foundation
import Security
import ServiceManagement

/// The app's side of the privileged helper (`DroboHelper/main.swift`): mounting and
/// unmounting for an account that is not allowed to do it itself.
///
/// The helper is a launchd daemon inside the app bundle, registered with SMAppService. macOS
/// asks an administrator to allow it once (Login Items & Extensions); after that each request
/// raises an administrator prompt under this app's name. Blocks, so call it off the main thread.
enum PrivilegedHelper {
    private enum Outcome {
        case finished(String?)
        /// The helper could not be reached at all (unsigned build, registration failed).
        case unavailable
    }

    /// Runs one diskutil verb on the given disks as root. Returns nil on success.
    static func diskutil(_ verb: String, disks: [String]) -> String? {
        switch viaHelper(verb, disks) {
        case .finished(let failure): return failure
        case .unavailable: return viaAppleScript(verb, disks)
        }
    }

    private static func viaHelper(_ verb: String, _ disks: [String]) -> Outcome {
        guard let appIdentifier = Bundle.main.bundleIdentifier,
              let team = DroboHelperIdentity.teamIdentifier() else { return .unavailable }
        let helperIdentifier = appIdentifier + DroboHelperIdentity.suffix
        guard let requirement = DroboHelperIdentity.requirement(identifier: helperIdentifier, team: team) else {
            return .unavailable
        }

        let daemon = SMAppService.daemon(plistName: helperIdentifier + ".plist")
        if daemon.status != .enabled { try? daemon.register() }
        switch daemon.status {
        case .enabled:
            break
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "this app"
            return .finished("An administrator has to allow \(name) once, under System Settings → General → "
                             + "Login Items & Extensions → Allow in the Background. Then try again.")
        default:
            return .unavailable
        }

        // An empty authorization: the helper asks for the right against it, and because this
        // process created it the prompt is shown under this app's name.
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else {
            return .unavailable
        }
        // Destroy the right afterwards so the next request asks again.
        defer { _ = AuthorizationFree(reference, [.destroyRights]) }
        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(reference, &form) == errAuthorizationSuccess else { return .unavailable }
        let authorization = withUnsafeBytes(of: form) { Data($0) }

        let connection = NSXPCConnection(machServiceName: helperIdentifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: DroboHelperProtocol.self)
        // Only talk to a helper signed by the same team as this app.
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }

        var outcome = Outcome.unavailable
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { _ in outcome = .unavailable }
        guard let helper = proxy as? DroboHelperProtocol else { return .unavailable }
        helper.diskutil(verb, disks: disks, authorization: authorization) { outcome = .finished($0) }
        return outcome
    }

    /// Fallback for builds whose helper cannot run: the same commands behind the system's
    /// AppleScript administrator prompt, which names `osascript` rather than this app.
    private static func viaAppleScript(_ verb: String, _ disks: [String]) -> String? {
        // Only verbs and BSD names are ever passed; refuse anything else instead of quoting it.
        let allowed = CharacterSet.alphanumerics
        guard DroboHelperIdentity.verbs.contains(verb), !disks.isEmpty,
              disks.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            return "Could not run diskutil."
        }
        let shell = disks.map { "/usr/sbin/diskutil \(verb) \($0)" }.joined(separator: " ; ")
        let script = "do shell script \"\(shell)\" "
            + "with prompt \"An administrator name and password is needed to mount or unmount Drobo volumes.\" "
            + "with administrator privileges"
        guard let result = DroboMonitor.runTool("/usr/bin/osascript", ["-e", script]) else {
            return "Could not ask for an administrator login."
        }
        if result.status == 0 { return nil }
        // -128 is AppleScript's "user cancelled".
        if result.output.contains("-128") { return "Administrator login was cancelled." }
        return result.output
    }
}
