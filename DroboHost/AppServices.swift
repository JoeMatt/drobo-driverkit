import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Which builds the update check looks at.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case off, release, nightly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .release: return "Releases"
        case .nightly: return "Nightly (every commit)"
        }
    }
}

/// Checks GitHub for a newer version.
///
/// This only tells you an update exists and opens the page. The app cannot replace itself yet:
/// until Apple grants the distribution entitlements there are no signed downloads, and every
/// installation is built and signed by its owner. Once notarized releases exist this is where a
/// real updater (for example Sparkle) plugs in.
final class UpdateChecker: ObservableObject {
    static let repository = "JoeMatt/drobo-driverkit"

    @Published var status = ""
    @Published var updateURL: URL?

    /// The commit this app was built from, written into the bundle by a build script.
    static var builtCommit: String {
        guard let url = Bundle.main.url(forResource: "commit", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func check(_ channel: UpdateChannel) {
        guard channel != .off else { status = ""; updateURL = nil; return }
        let path = channel == .release ? "releases/latest" : "commits/master"
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/\(path)") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        status = "Checking…"
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            DispatchQueue.main.async { self?.finish(channel, code: code, json: json) }
        }.resume()
    }

    private func finish(_ channel: UpdateChannel, code: Int, json: [String: Any]?) {
        updateURL = nil
        guard code == 200, let json else {
            // 404 on releases/latest simply means nothing has been released yet.
            status = (channel == .release && code == 404) ? "No releases published yet." : "Could not check for updates."
            return
        }
        switch channel {
        case .release:
            let tag = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if !tag.isEmpty, tag.compare(Self.version, options: .numeric) == .orderedDescending {
                status = "Version \(tag) is available (you have \(Self.version))."
                updateURL = (json["html_url"] as? String).flatMap(URL.init(string:))
            } else {
                status = "Up to date (\(Self.version))."
            }
        case .nightly:
            let sha = json["sha"] as? String ?? ""
            let built = Self.builtCommit
            if built.isEmpty {
                status = "This build does not record its commit, so nightly checks cannot compare."
            } else if !sha.isEmpty, sha != built {
                status = "Newer commits are available (you have \(built.prefix(7)), latest is \(sha.prefix(7)))."
                updateURL = URL(string: "https://github.com/\(Self.repository)/compare/\(built)...\(sha)")
            } else {
                status = "Up to date (\(built.prefix(7)))."
            }
        case .off:
            break
        }
    }
}

/// Launch at login, using the system's login-item service for the app itself.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns nil on success, or why it failed.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Posts a notification when the Drobo's condition changes.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Installs the bundled `drobo` command by linking it into /usr/local/bin, and reports whether
/// it is installed. The link points into this app, so the command updates with the app.
///
/// /usr/local/bin usually needs an administrator, so when a plain link fails this asks macOS
/// for an administrator password with the system's own dialog. The app never sees the password.
final class CommandLineTool: ObservableObject {
    static let linkPath = "/usr/local/bin/drobo"

    enum State: Equatable {
        case unavailable            // this build has no bundled command
        case notInstalled
        case installed              // links to this app
        case elsewhere(String)      // links somewhere else, e.g. another copy of the app
        case blocked                // a real file is at the path; never replaced
    }

    @Published private(set) var state = State.notInstalled

    static var bundledPath: String? { Bundle.main.url(forAuxiliaryExecutable: "drobo")?.path }

    init() { refresh() }

    func refresh() {
        guard let bundled = Self.bundledPath else { state = .unavailable; return }
        let files = FileManager.default
        if let target = try? files.destinationOfSymbolicLink(atPath: Self.linkPath) {
            state = target == bundled ? .installed : .elsewhere(target)
        } else {
            state = files.fileExists(atPath: Self.linkPath) ? .blocked : .notInstalled
        }
    }

    var statusText: String {
        switch state {
        case .unavailable: return "This build does not include the command."
        case .notInstalled: return "Not installed."
        case .installed: return "Installed at \(Self.linkPath)."
        case .elsewhere(let target): return "\(Self.linkPath) points to another copy: \(target)"
        case .blocked: return "Another file is already at \(Self.linkPath). Move it away to install."
        }
    }

    /// Title for the menu item and button that acts on the current state.
    var actionTitle: String {
        switch state {
        case .installed: return "Uninstall Command Line Tool…"
        case .elsewhere: return "Update Command Line Tool…"
        default: return "Install Command Line Tool…"
        }
    }

    var canAct: Bool { state != .unavailable && state != .blocked }

    /// Installs, re-points or removes the link depending on the current state, then says what
    /// happened in an alert (this is called from menus, where there is nowhere else to say it).
    func performAction() {
        refresh()
        let removing = state == .installed
        let failure: String?
        switch state {
        case .unavailable, .blocked: failure = statusText
        case .installed: failure = uninstall()
        case .notInstalled, .elsewhere: failure = install()
        }
        refresh()
        guard failure != "" else { return }          // cancelled at the password prompt
        let alert = NSAlert()
        if let failure {
            alert.alertStyle = .warning
            alert.messageText = removing ? "Could not remove the command" : "Could not install the command"
            alert.informativeText = failure
        } else {
            alert.messageText = removing ? "Command line tool removed" : "Command line tool installed"
            alert.informativeText = removing
                ? "\(Self.linkPath) was removed."
                : "Open a new terminal window and type drobo. It is read-only: it shows status and never sends anything to the Drobo."
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// nil on success, "" if the user cancelled, otherwise why it failed.
    private func install() -> String? {
        guard let bundled = Self.bundledPath else { return statusText }
        let files = FileManager.default
        do {
            try files.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            if (try? files.destinationOfSymbolicLink(atPath: Self.linkPath)) != nil {
                try files.removeItem(atPath: Self.linkPath)
            }
            try files.createSymbolicLink(atPath: Self.linkPath, withDestinationPath: bundled)
            return nil
        } catch {
            return privileged("/bin/mkdir -p /usr/local/bin && /bin/ln -sfn \(Self.quoted(bundled)) \(Self.linkPath)")
        }
    }

    private func uninstall() -> String? {
        do {
            try FileManager.default.removeItem(atPath: Self.linkPath)
            return nil
        } catch {
            return privileged("/bin/rm \(Self.linkPath)")
        }
    }

    /// Single-quotes a path for the shell.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func privileged(_ command: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"Drobo DriverKit wants to change the drobo command in /usr/local/bin.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "" }
        return error[NSAppleScript.errorMessage] as? String ?? "The system refused the change."
    }
}
