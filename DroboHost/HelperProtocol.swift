import Foundation
import Security

/// What the app may ask the privileged helper (`DroboHelper/main.swift`) to do. Compiled into
/// both. The helper runs as root, so the interface is deliberately this narrow: one diskutil
/// verb from a fixed list, applied to disks the helper itself confirms belong to the Drobo.
@objc protocol DroboHelperProtocol {
    /// `authorization` is an `AuthorizationExternalForm` made by the app. The helper asks
    /// macOS for the mount right against it, which is what shows the administrator prompt
    /// under the app's name. Replies nil on success, otherwise what went wrong.
    func diskutil(_ verb: String, disks: [String], authorization: Data, reply: @escaping (String?) -> Void)
}

enum DroboHelperIdentity {
    /// The helper's bundle identifier, launchd label and Mach service name are all the app's
    /// bundle identifier plus this, so each side can work out the other's from its own.
    static let suffix = ".helper"

    /// The authorization right an administrator has to grant, named after the app.
    static func rightName(appIdentifier: String) -> String { appIdentifier + ".mount" }

    static let verbs = ["mountDisk", "unmountDisk", "unmount"]

    /// Team ID the running code was signed with; nil if it is unsigned or ad-hoc signed.
    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }

    /// Code-signing requirement for the other end of the connection: that exact identifier,
    /// signed by the same team as this process. nil if either would not be safe to quote.
    static func requirement(identifier: String, team: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !identifier.isEmpty, !team.isEmpty,
              (identifier + team).unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
