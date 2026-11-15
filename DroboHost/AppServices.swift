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
