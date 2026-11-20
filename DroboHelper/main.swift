import Foundation
import Security

// The privileged helper: a launchd daemon the app registers with SMAppService, running as
// root. It exists so a standard (non-admin) account can mount and unmount the Drobo's volumes
// after an administrator authenticates in a prompt that carries the app's name.
//
// It never talks to the Drobo or the driver. All it runs is
// `/usr/sbin/diskutil mountDisk|unmountDisk|unmount <disk>`, and only when:
//   1. the caller is the host app, signed by the same team as this helper (enforced by
//      launchd/XPC from the requirement set on the listener below);
//   2. every disk named is on one of the Drobo's units, checked here in the IORegistry;
//   3. macOS grants the app's mount right for the authorization the caller sent, which
//      means an administrator has just authenticated.

final class HelperService: NSObject, NSXPCListenerDelegate, DroboHelperProtocol {
    private let rightName: String
    private let lock = NSLock()
    private var connections = 0

    init(rightName: String) {
        self.rightName = rightName
    }

    /// Defines the right if this Mac does not have it yet: any administrator may grant it.
    /// Without a definition macOS falls back to its default rule, which also needs an
    /// administrator, so a failure here is not fatal.
    func ensureRight() {
        guard AuthorizationRightGet(rightName, nil) != errAuthorizationSuccess else { return }
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return }
        defer { _ = AuthorizationFree(reference, []) }
        _ = AuthorizationRightSet(reference, rightName, "authenticate-admin" as CFString,
                                  "An administrator is needed to mount or unmount Drobo volumes." as CFString, nil, nil)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DroboHelperProtocol.self)
        connection.exportedObject = self
        lock.lock(); connections += 1; lock.unlock()
        connection.invalidationHandler = { [weak self] in self?.connectionClosed() }
        connection.resume()
        return true
    }

    /// Exits once nothing is connected. launchd starts the helper again on demand, and that
    /// way an updated app is never served by the previous version's helper.
    private func connectionClosed() {
        lock.lock(); connections -= 1; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let idle = self.connections <= 0; self.lock.unlock()
            if idle { exit(0) }
        }
    }

    func diskutil(_ verb: String, disks: [String], authorization: Data, reply: @escaping (String?) -> Void) {
        guard DroboHelperIdentity.verbs.contains(verb), !disks.isEmpty, disks.count <= 64,
              disks.allSatisfy(Self.isBSDName) else {
            reply("The helper refused the request.")
            return
        }
        guard disks.allSatisfy({ DroboMonitor.isDroboDisk(bsdName: $0) }) else {
            reply("The helper only mounts and unmounts Drobo disks.")
            return
        }
        let status = authorize(authorization)
        guard status == errAuthorizationSuccess else {
            reply(status == errAuthorizationCanceled ? "Administrator login was cancelled."
                                                     : "An administrator did not authorise this (\(status)).")
            return
        }
        let failures = disks.compactMap { DroboMonitor.diskutil(verb, $0) }
        reply(failures.isEmpty ? nil : failures.joined(separator: "\n"))
    }

    /// "disk" plus a number, optionally followed by slice numbers: disk5, disk5s1, disk5s1s1.
    private static func isBSDName(_ name: String) -> Bool {
        guard name.hasPrefix("disk"), name.count <= 16 else { return false }
        let parts = name.dropFirst(4).split(separator: "s", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
    }

    /// Asks macOS for the mount right against the caller's authorization. Because the app
    /// created that authorization, the prompt this raises is shown under the app's name.
    private func authorize(_ data: Data) -> OSStatus {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return errAuthorizationInvalidRef }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { $0.copyBytes(from: data) }
        var reference: AuthorizationRef?
        let created = AuthorizationCreateFromExternalForm(&form, &reference)
        guard created == errAuthorizationSuccess, let reference else {
            return created == errAuthorizationSuccess ? errAuthorizationInvalidRef : created
        }
        defer { _ = AuthorizationFree(reference, []) }
        return rightName.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items -> OSStatus in
                var rights = AuthorizationRights(count: 1, items: items)
                return AuthorizationCopyRights(reference, &rights, nil, [.extendRights, .interactionAllowed], nil)
            }
        }
    }
}

// Unsigned and ad-hoc signed builds have no team to hold the caller to, so they do not serve.
guard let helperIdentifier = Bundle.main.bundleIdentifier,
      helperIdentifier.hasSuffix(DroboHelperIdentity.suffix),
      let team = DroboHelperIdentity.teamIdentifier() else { exit(1) }
let appIdentifier = String(helperIdentifier.dropLast(DroboHelperIdentity.suffix.count))
guard let requirement = DroboHelperIdentity.requirement(identifier: appIdentifier, team: team) else { exit(1) }

let service = HelperService(rightName: DroboHelperIdentity.rightName(appIdentifier: appIdentifier))
service.ensureRight()
let listener = NSXPCListener(machServiceName: helperIdentifier)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = service
listener.resume()
RunLoop.main.run()
