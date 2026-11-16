import Combine
import Foundation

/// One change in what the Drobo reports about a bay.
struct BayChange: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let bay: Int
    let statusCode: UInt8
    var errorCount: Int?
    var diskState: UInt32?
    var model = ""
    /// How many Drobo restarts this history had seen when the change was recorded. Two changes
    /// with different values have a restart between them.
    var boot = 0

    /// The Drobo is complaining about this drive (as opposed to healthy, rebuilding or empty).
    var isFault: Bool { BayHistory.isFault(statusCode) }
}

/// A stretch of time a bay spent flagged.
struct BayEpisode: Identifiable {
    let start: Date
    var end: Date?
    var worstCode: UInt8
    var clearedByRestart = false
    var spannedRestart = false
    var id: Date { start }
}

enum BayVerdict: String {
    case empty, steady, intermittent, flagged, persistent

    var label: String {
        switch self {
        case .empty: return "Empty"
        case .steady: return "Steady"
        case .intermittent: return "Intermittent"
        case .flagged: return "Flagged"
        case .persistent: return "Likely failing"
        }
    }
}

struct BayAnalysis: Identifiable {
    let bay: Int
    var model = ""
    var statusCode: UInt8 = 0x80
    var verdict = BayVerdict.empty
    var episodes: [BayEpisode] = []
    var errorRise = 0
    var summary = ""
    /// Status over the window, oldest first, for the timeline strip. Each entry holds until the next.
    var spans: [(date: Date, statusCode: UInt8)] = []
    var id: Int { bay }
    var name: String { bay < 8 ? "Bay \(bay + 1)" : "SSD bay" }
}

struct BayReport {
    var window: TimeInterval = 0
    var since: Date?
    var bays: [BayAnalysis] = []
    var restarts: [Date] = []
    /// What the pattern across all bays suggests; empty when there is nothing to say.
    var headline = ""
    var advice = ""
    var enclosureSuspected = false
}

struct BayHistoryFile: Codable {
    var changes: [BayChange] = []
    var restarts: [Date] = []
}

/// Per-bay status over time, kept across app and Drobo restarts, and what the pattern says:
/// a drive that is flagged and then comes back after a restart is intermittent; several bays
/// doing that points at the enclosure rather than at each drive.
///
/// Only covers time the app (or its menu bar item) was running. Reads what the Drobo already
/// reports; sends nothing.
final class BayHistory: ObservableObject {
    @Published private(set) var file = BayHistoryFile()

    /// Called with a one-line finding when the cross-bay conclusion changes.
    var onHeadline: ((String, String) -> Void)?

    private let persist: Bool
    private let changeLimit = 5000
    private var wasReady: Bool?
    private var lastHeadline = ""

    static let defaultWindow: TimeInterval = 14 * 86_400

    static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("DroboDriverKit", isDirectory: true).appendingPathComponent("bays.json")
    }

    static func isFault(_ code: UInt8) -> Bool {
        guard code != 0x80 else { return false }
        switch code & 0x0F {
        case 1, 2, 5, 6: return true
        default: return false
        }
    }

    static func load() -> BayHistoryFile {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return BayHistoryFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(BayHistoryFile.self, from: data)) ?? BayHistoryFile()
    }

    init(persist: Bool) {
        self.persist = persist
        if persist { file = Self.load() }
        lastHeadline = Self.analyze(file).headline
    }

    func clear() {
        file = BayHistoryFile()
        lastHeadline = ""
        save()
    }

    func seed(_ seeded: BayHistoryFile) { file = seeded }

    private func save() {
        guard persist, let url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// A restart at `date`, unless one is already recorded close to it (the same restart is seen
    /// twice: once when the Drobo stops answering, once from its uptime counter).
    private func noteRestart(_ date: Date) -> Bool {
        if file.restarts.contains(where: { abs($0.timeIntervalSince(date)) < 600 }) { return false }
        file.restarts.append(date)
        file.restarts.sort()
        if file.restarts.count > 500 { file.restarts.removeFirst(file.restarts.count - 500) }
        return true
    }

    /// Called once per poll.
    func record(_ snapshot: DroboSnapshot, now: Date = Date()) {
        var changed = false
        if snapshot.driverPresent {
            if wasReady == false, snapshot.ready, noteRestart(now) { changed = true }
            wasReady = snapshot.ready
        }
        guard snapshot.ready, snapshot.healthAvailable, !snapshot.slots.isEmpty else {
            if changed { save() }
            return
        }
        // The uptime counter dates the restart exactly, and catches ones that happened while
        // the app was not running.
        if let uptime = snapshot.uptime, uptime > 0 {
            let bootDate = now.addingTimeInterval(-Double(uptime))
            if (file.restarts.last.map { bootDate.timeIntervalSince($0) > 600 } ?? true), noteRestart(bootDate) { changed = true }
        }
        let boot = file.restarts.count

        for slot in snapshot.slots {
            let last = file.changes.last { $0.bay == slot.id }
            let errors = slot.errorCount.map { Int($0) }
            let same = last.map { previous in
                previous.statusCode == slot.statusCode
                    && (errors == nil || previous.errorCount == nil || previous.errorCount == errors)
                    && (slot.diskState == nil || previous.diskState == nil || previous.diskState == slot.diskState)
                    && (slot.isEmpty || previous.model == slot.model)
            } ?? false
            if same { continue }
            // Nothing worth a first entry for a bay that has always been empty.
            if last == nil, slot.isEmpty { continue }
            file.changes.append(BayChange(date: now, bay: slot.id, statusCode: slot.statusCode,
                                          errorCount: errors ?? last?.errorCount, diskState: slot.diskState ?? last?.diskState,
                                          model: slot.isEmpty ? (last?.model ?? "") : slot.model, boot: boot))
            changed = true
        }
        guard changed else { return }
        if file.changes.count > changeLimit { file.changes.removeFirst(file.changes.count - changeLimit) }
        save()

        let report = Self.analyze(file, now: now)
        if report.headline != lastHeadline {
            lastHeadline = report.headline
            if !report.headline.isEmpty { onHeadline?(report.headline, report.advice) }
        }
    }

    // MARK: Analysis

    static func bayList(_ bays: [Int]) -> String {
        let names = bays.sorted().map { $0 < 8 ? "\($0 + 1)" : "SSD" }
        guard names.count > 1 else { return "Bay \(names.first ?? "?")" }
        return "Bays " + names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    static func analyze(_ file: BayHistoryFile, window: TimeInterval = defaultWindow, now: Date = Date()) -> BayReport {
        let cutoff = now.addingTimeInterval(-window)
        var report = BayReport()
        report.window = window
        report.since = file.changes.first?.date
        report.restarts = file.restarts.filter { $0 >= cutoff }
        let boot = file.restarts.count

        for bay in Set(file.changes.map(\.bay)).sorted() {
            let all = file.changes.filter { $0.bay == bay }
            guard let latest = all.last else { continue }
            var analysis = BayAnalysis(bay: bay, model: latest.model, statusCode: latest.statusCode)

            // Timeline: the state in force at the start of the window, then each change in it.
            if let before = all.last(where: { $0.date < cutoff }) { analysis.spans.append((cutoff, before.statusCode)) }
            analysis.spans += all.filter { $0.date >= cutoff }.map { ($0.date, $0.statusCode) }

            // Episodes: runs of consecutive fault states.
            var open: (episode: BayEpisode, boot: Int)?
            for change in all {
                if change.isFault {
                    if var current = open {
                        if change.statusCode & 0x0F == 1 || change.statusCode & 0x0F == 6 { current.episode.worstCode = change.statusCode }
                        if change.boot != current.boot { current.episode.spannedRestart = true }
                        open = current
                    } else {
                        open = (BayEpisode(start: change.date, worstCode: change.statusCode), change.boot)
                    }
                } else if var current = open {
                    current.episode.end = change.date
                    current.episode.clearedByRestart = change.boot != current.boot
                    if change.date >= cutoff { analysis.episodes.append(current.episode) }
                    open = nil
                }
            }
            if var current = open {
                if boot != current.boot { current.episode.spannedRestart = true }
                analysis.episodes.append(current.episode)
            }

            let inWindow = all.filter { $0.date >= cutoff }.compactMap(\.errorCount)
            let baseline = all.last(where: { $0.date < cutoff })?.errorCount ?? inWindow.first
            if let first = baseline, let last = inWindow.last, last > first { analysis.errorRise = last - first }

            let closed = analysis.episodes.filter { $0.end != nil }
            let afterRestart = closed.filter(\.clearedByRestart).count
            let times = { (count: Int) in count == 1 ? "once" : "\(count) times" }
            if latest.statusCode == 0x80 {
                analysis.verdict = .empty
                analysis.summary = closed.isEmpty ? "Empty." : "Empty now. Was flagged \(times(closed.count)) before that."
            } else if latest.isFault, let current = analysis.episodes.last {
                if current.spannedRestart || closed.count >= 2 {
                    analysis.verdict = .persistent
                    analysis.summary = current.spannedRestart
                        ? "Still flagged after a restart. That points at this drive."
                        : "Flagged again, after \(times(closed.count)) before. That points at this drive or its bay."
                } else {
                    analysis.verdict = .flagged
                    analysis.summary = closed.isEmpty
                        ? "Flagged for the first time in this history. One occurrence does not say whether it is the drive."
                        : "Flagged again; it recovered \(times(closed.count)) before."
                }
            } else if !closed.isEmpty {
                analysis.verdict = .intermittent
                let restartNote = afterRestart == 0 ? "." : " (\(afterRestart < closed.count ? times(afterRestart) + " " : closed.count > 1 ? "each time " : "")after a restart)."
                analysis.summary = "Flagged \(times(closed.count)) and recovered" + restartNote
            } else {
                analysis.verdict = .steady
                analysis.summary = "No problems recorded."
            }
            if analysis.errorRise > 0 { analysis.summary += " Error count up by \(analysis.errorRise)." }
            report.bays.append(analysis)
        }

        // What the bays have in common.
        let troubled = report.bays.filter { !$0.episodes.isEmpty }
        let recovered = troubled.filter { bay in bay.episodes.contains { $0.end != nil } }
        let worst = troubled.max { $0.episodes.count < $1.episodes.count }
        if recovered.count >= 2 {
            report.enclosureSuspected = true
            report.headline = "\(bayList(recovered.map(\.bay))) have each been flagged and then recovered"
            report.advice = "Separate drives rarely fail and come back together. This pattern points at something the bays share: the power supply, the backplane or the drive controller. Replacing drives is unlikely to cure it; try a known-good power supply first."
            if let worst = worst, worst.episodes.count >= 3 {
                let others = troubled.filter { $0.bay != worst.bay }
                if others.allSatisfy({ $0.episodes.count * 2 <= worst.episodes.count }) {
                    report.advice += " \(worst.name) is flagged far more often than the others (\(worst.episodes.count) times) and may also be bad in its own right."
                }
            }
        } else if let only = troubled.first, troubled.count == 1 {
            if only.verdict == .persistent {
                report.headline = "\(only.name) keeps being flagged and no other bay is"
                report.advice = "That points at the drive in \(only.name.lowercased()), or that bay's connector. Replace it once the Drobo is protected again; do not pull a drive while there is no redundancy."
            } else if only.verdict == .intermittent, only.episodes.count >= 2 {
                report.headline = "\(only.name) has been flagged \(only.episodes.count) times and recovered each time"
                report.advice = "Only this bay is affected, which points at the drive or its connector rather than the enclosure. Plan to replace it."
            }
        } else if troubled.count >= 2 {
            report.headline = "\(bayList(troubled.map(\.bay))) are flagged"
            report.advice = "Several bays at once can be the enclosure rather than the drives. Whether they recover after a restart will tell: if they do, suspect the power supply or backplane."
        }
        return report
    }
}

extension BayHistoryFile {
    /// Made-up history for demo mode: one bay that keeps dropping, two that did it once.
    static func demo(rebuilding: Bool, now: Date = Date()) -> BayHistoryFile {
        var file = BayHistoryFile()
        let models = ["WDC WD80EFAX", "WDC WD80EFAX", "ST8000VN004", "ST8000VN004", "WDC WD40EFRX", "WDC WD40EFRX"]
        let day = 86_400.0
        file.restarts = [-9.4, -6.1, -3.2, -1.3].map { now.addingTimeInterval($0 * day) }
        func add(_ offset: Double, _ bay: Int, _ code: UInt8, errors: Int = 0) {
            let date = now.addingTimeInterval(offset * day)
            file.changes.append(BayChange(date: date, bay: bay, statusCode: code, errorCount: errors, diskState: 0x10,
                                          model: models[bay], boot: file.restarts.filter { $0 <= date }.count))
        }
        for bay in 0..<6 { add(-13.5, bay, 3) }
        add(-9.9, 4, 5); add(-9.39, 4, 3)
        add(-6.6, 4, 1, errors: 3); add(-6.5, 5, 5); add(-6.09, 4, 3, errors: 3); add(-6.09, 5, 3)
        add(-3.5, 4, 5, errors: 9); add(-3.4, 1, 5); add(-3.19, 4, 3, errors: 9); add(-3.19, 1, 3)
        if rebuilding { add(-0.2, 2, 4, errors: 14) }
        file.changes.sort { $0.date < $1.date }
        return file
    }
}
