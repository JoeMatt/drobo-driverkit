import AppKit
import SwiftUI

/// The Finder icon for a Drobo volume: a dark drive with a ten-light bar showing how full the
/// volume is, to the nearest tenth, as Drobo Dashboard's volume icons did.
struct VolumeIconArt: View {
    /// Lights lit, 0...10.
    let tenths: Int

    var body: some View {
        let body = RoundedRectangle(cornerRadius: 120, style: .continuous)
        ZStack {
            body.fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
            body.fill(RadialGradient(colors: [Theme.emerald.opacity(0.30), .clear], center: .topLeading, startRadius: 0, endRadius: 620))
            body.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 5)
            VStack(spacing: 0) {
                // Front panel: two columns of bay slats.
                HStack(spacing: 26) {
                    ForEach(0..<2, id: \.self) { _ in
                        VStack(spacing: 20) {
                            ForEach(0..<4, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(Color.white.opacity(0.07))
                                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.13), lineWidth: 3))
                                    .frame(height: 62)
                            }
                        }
                    }
                }
                .padding(.horizontal, 74).padding(.top, 70)
                Spacer(minLength: 0)
                // Capacity lights.
                HStack(spacing: 22) {
                    ForEach(0..<10, id: \.self) { index in
                        let lit = index < tenths
                        let color = tenths >= 10 ? Theme.coral : (tenths >= 9 ? Theme.amber : Theme.ice)
                        Circle()
                            .fill(lit ? color : Color.white.opacity(0.12))
                            .frame(width: 44, height: 44)
                            .shadow(color: lit ? color.opacity(0.9) : .clear, radius: 16)
                    }
                }
                .padding(.bottom, 70)
            }
        }
        .frame(width: 824, height: 660)
        .shadow(color: .black.opacity(0.45), radius: 22, y: 14)
        .frame(width: 1024, height: 1024)
    }
}

/// Sets and clears custom Finder icons on Drobo volumes.
///
/// A volume's icon is a file on the volume itself (`.VolumeIcon.icns` plus a flag on its root),
/// which is also how Drobo Dashboard did it. So this **writes to the volume**: it only works where
/// "Allow writes" is on, and the app only does it when asked, per volume.
enum VolumeIcons {
    private static let knownKey = "volumeIconTenths"      // volume UUID -> lights last drawn

    /// How full the volume is, in tenths, from the file system.
    static func tenths(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity, total > 0 else { return nil }
        let used = Double(total - free) / Double(total)
        return min(10, max(0, Int((used * 10).rounded())))
    }

    private static func identifier(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    @MainActor private static func image(tenths: Int) -> NSImage? {
        let renderer = ImageRenderer(content: VolumeIconArt(tenths: tenths))
        renderer.scale = 1
        return renderer.nsImage
    }

    /// True if this app has put its icon on the volume.
    static func isSet(on url: URL) -> Bool {
        guard let id = identifier(of: url) else { return false }
        return (UserDefaults.standard.dictionary(forKey: knownKey) ?? [:])[id] != nil
    }

    /// Writes the icon. Returns nil on success, or why it failed.
    @MainActor static func apply(to url: URL) -> String? {
        guard let level = tenths(of: url) else { return "Could not read how full the volume is." }
        guard let icon = image(tenths: level) else { return "Could not draw the icon." }
        guard NSWorkspace.shared.setIcon(icon, forFile: url.path, options: []) else {
            return "Could not write the icon. The volume must allow writes."
        }
        remember(url, level)
        return nil
    }

    /// Removes the icon. Returns nil on success, or why it failed.
    static func remove(from url: URL) -> String? {
        guard NSWorkspace.shared.setIcon(nil, forFile: url.path, options: []) else {
            return "Could not remove the icon. The volume must allow writes."
        }
        remember(url, nil)
        return nil
    }

    /// Redraws icons this app set earlier when a volume's fullness has moved to another tenth.
    /// Called from the poll; does nothing for volumes it never touched or that are read-only.
    @MainActor static func refresh(writable urls: [URL]) {
        let known = UserDefaults.standard.dictionary(forKey: knownKey) as? [String: Int] ?? [:]
        for url in urls {
            guard let id = identifier(of: url), let drawn = known[id], let now = tenths(of: url), now != drawn else { continue }
            _ = apply(to: url)
        }
    }

    private static func remember(_ url: URL, _ level: Int?) {
        guard let id = identifier(of: url) else { return }
        var known = UserDefaults.standard.dictionary(forKey: knownKey) ?? [:]
        known[id] = level
        UserDefaults.standard.set(known, forKey: knownKey)
    }
}
