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
    /// Readings at the moment of the change, when the Drobo reports them.
    var temperature: Int?
    var enclosureTemperature: Int?
    var fans: [Int]?

    /// The Drobo is complaining about this drive (as opposed to healthy, rebuilding or empty).
    var isFault: Bool { BayHistory.isFault(statusCode) || (statusCode != 0x80 && (diskState.map { $0 & 0x0F >= 2 } ?? false)) }
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
    /// Drive temperature over the window, oldest first, thinned for drawing.
    var temperatures: [(date: Date, value: Int)] = []
    var temperatureLow: Int?
    var temperatureHigh: Int?
    var temperatureNow: Int?
    var id: Int { bay }
    /// "34–41 °C, last 38 °C", or empty when nothing was recorded.
    var temperatureText: String {
        guard let low = temperatureLow, let high = temperatureHigh else { return "" }
        let range = low == high ? "\(low) °C" : "\(low)–\(high) °C"
        return temperatureNow.map { "\(range), last \($0) °C" } ?? range
    }
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
    /// Set when every flagged bay holds this one model and no healthy bay does.
    var sharedModel = ""
    /// Enclosure temperature over the window, thinned for drawing.
    var enclosureTemperatures: [(date: Date, value: Int)] = []
    var enclosureLow: Int?
    var enclosureHigh: Int?
    /// Each flagging in the window for which a drive temperature is known.
    var faultReadings: [FaultReading] = []
    /// What the temperatures say about the faults, or about a drive running hot now. Empty when
    /// there is nothing to go on.
    var heatNote = ""
    var heatSuspected = false
}

/// Temperatures at one moment: the enclosure's, and each occupied bay's drive.
struct ThermalSample: Codable {
    let date: Date
    var enclosure: Int?
    var fans: [Int] = []
    /// Degrees Celsius by bay number.
    var drives: [Int: Int] = [:]
}

/// A drive's temperature when it was flagged, against what is normal for it.
struct FaultReading {
    let bay: Int
    let date: Date
    let temperature: Int
    /// This drive's median over the window.
    var usual: Int?
    /// The other drives' median at the same moment.
    var others: Int?

    var isHot: Bool {
        temperature >= BayHistory.hotDrive
            || (usual.map { temperature >= $0 + BayHistory.hotMargin } ?? false)
            || (others.map { temperature >= $0 + BayHistory.hotMargin } ?? false)
    }
}

/// A temperature or fan condition starting, getting worse, or ending.
struct ThermalAlert {
    /// 0 back to normal, 1 warning, 2 critical.
    let severity: Int
    let title: String
    let detail: String
}

struct BayHistoryFile: Codable {
    var changes: [BayChange] = []
    var restarts: [Date] = []
    var samples: [ThermalSample] = []

    init() {}

    // Files written before temperatures were kept have no samples.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changes = try container.decodeIfPresent([BayChange].self, forKey: .changes) ?? []
        restarts = try container.decodeIfPresent([Date].self, forKey: .restarts) ?? []
        samples = try container.decodeIfPresent([ThermalSample].self, forKey: .samples) ?? []
    }
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
    private let sampleLimit = 4500

    /// Seconds between temperature samples.
    static let sampleInterval: TimeInterval = 300
    /// A drive at or above this is called hot outright. Most drives are rated to about 60 °C.
    static let hotDrive = 50
    /// Degrees above its own usual reading, or above the other drives, that counts as hot.
    static let hotMargin = 8
    static let criticalDrive = 58
    /// The enclosure sensor sits away from the drives and reads much lower than they do, so its
    /// limits are lower, and a rise above its own usual reading matters more than either.
    static let warmEnclosure = 45
    static let criticalEnclosure = 55
    /// Degrees a reading must fall below a limit before the condition counts as over.
    static let hysteresis = 3

    /// Conditions in force, by name, with their severity.
    private var thermalState: [String: Int] = [:]
    private var enclosureUsual: Int?
    private var fanCount = 0
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
        case 1, 2, 5, 6, 7, 8: return true
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
                                          model: slot.isEmpty ? (last?.model ?? "") : slot.model, boot: boot,
                                          temperature: slot.isEmpty ? nil : slot.temperature,
                                          enclosureTemperature: snapshot.systemTemperature,
                                          fans: snapshot.fanLevels.isEmpty ? nil : snapshot.fanLevels.map { Int($0) }))
            changed = true
        }
        // A sample on every change as well as on the clock, so each flagging has the other
        // drives' temperatures beside it.
        let sampled = sample(snapshot, now: now, force: changed)
        guard changed || sampled else { return }
        if file.changes.count > changeLimit { file.changes.removeFirst(file.changes.count - changeLimit) }
        save()
        guard changed else { return }

        let report = Self.analyze(file, now: now)
        if report.headline != lastHeadline {
            lastHeadline = report.headline
            if !report.headline.isEmpty { onHeadline?(report.headline, report.advice) }
        }
    }

    /// Keeps the temperatures the Drobo reports, at most once per `sampleInterval` unless forced.
    private func sample(_ snapshot: DroboSnapshot, now: Date, force: Bool) -> Bool {
        if !force, let last = file.samples.last, now.timeIntervalSince(last.date) < Self.sampleInterval { return false }
        var entry = ThermalSample(date: now, enclosure: snapshot.systemTemperature, fans: snapshot.fanLevels.map { Int($0) })
        for slot in snapshot.slots where !slot.isEmpty {
            if let temperature = slot.temperature { entry.drives[slot.id] = temperature }
        }
        guard entry.enclosure != nil || !entry.drives.isEmpty else { return false }
        file.samples.append(entry)
        // "Usual" needs a fair stretch of readings behind it before a rise above it means much.
        let enclosure = file.samples.compactMap(\.enclosure)
        if let first = file.samples.first, now.timeIntervalSince(first.date) >= 6 * 3600, enclosure.count >= 50 {
            enclosureUsual = Self.median(enclosure)
        }
        let cutoff = now.addingTimeInterval(-Self.defaultWindow)
        if let first = file.samples.first, first.date < cutoff { file.samples.removeAll { $0.date < cutoff } }
        if file.samples.count > sampleLimit { file.samples.removeFirst(file.samples.count - sampleLimit) }
        return true
    }

    // MARK: Temperature and fan warnings

    /// Called once per poll, after `record`. Returns what has just started, worsened or ended.
    /// Works from whatever the Drobo reports: some models give no drive temperatures or no fan
    /// page, and then only the enclosure reading is watched.
    func thermalAlerts(_ snapshot: DroboSnapshot) -> [ThermalAlert] {
        guard snapshot.ready, snapshot.healthAvailable else { return [] }
        var alerts: [ThermalAlert] = []

        func judge(_ key: String, _ value: Int, warn: Int, critical: Int, name: String, advice: String) {
            let before = thermalState[key] ?? 0
            var level = value >= critical ? 2 : (value >= warn ? 1 : 0)
            // Hold the earlier level until the reading is clearly below its limit.
            if level < before {
                let limit = before == 2 ? critical : warn
                if value > limit - Self.hysteresis { level = before }
            }
            guard level != before else { return }
            thermalState[key] = level
            if level > before {
                alerts.append(ThermalAlert(severity: level, title: "\(name) is at \(value) °C", detail: advice))
            } else if level == 0 {
                alerts.append(ThermalAlert(severity: 0, title: "\(name) is back to \(value) °C", detail: ""))
            }
        }

        if let enclosure = snapshot.systemTemperature {
            var warn = Self.warmEnclosure
            var note = "Check that the fans are turning and that air is coming out of the back."
            if let usual = enclosureUsual, usual + Self.hotMargin < warn {
                warn = usual + Self.hotMargin
                note = "It usually reads about \(usual) °C. " + note
            }
            judge("enclosure", enclosure, warn: warn, critical: max(Self.criticalEnclosure, warn + 5), name: "The Drobo's enclosure", advice: note)
        }
        for slot in snapshot.slots where !slot.isEmpty {
            guard let temperature = slot.temperature else { continue }
            judge("bay\(slot.id)", temperature, warn: Self.hotDrive, critical: Self.criticalDrive,
                  name: "The drive in \(Self.bayList([slot.id]).lowercased())",
                  advice: "Most drives are rated to about 60 °C. Check the fans and the airflow around the Drobo.")
        }
        // A fan that stops reporting a speed, on models that report fans at all.
        let fans = snapshot.fanLevels.count
        if fans > 0 || fanCount > 0 {
            let before = thermalState["fans"] ?? 0
            let level = fans < fanCount ? 1 : 0
            if level != before {
                thermalState["fans"] = level
                alerts.append(level == 1
                    ? ThermalAlert(severity: 1, title: "A fan has stopped reporting a speed",
                                   detail: "\(fans) of \(fanCount) fans report a speed now. Check that they are all turning.")
                    : ThermalAlert(severity: 0, title: "All fans report a speed again", detail: ""))
            }
            fanCount = max(fanCount, fans)
        }
        return alerts
    }

    // MARK: Analysis

    private static func median(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }

    /// At most `limit` points, evenly spaced, always keeping the last.
    private static func thinned(_ points: [(date: Date, value: Int)], limit: Int = 240) -> [(date: Date, value: Int)] {
        guard points.count > limit, let last = points.last else { return points }
        let step = Double(points.count) / Double(limit)
        return (0..<limit).map { points[Int(Double($0) * step)] } + [last]
    }

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
        let samples = file.samples.filter { $0.date >= cutoff }
        var onsets: [BayChange] = []

        let enclosure = samples.compactMap { sample in sample.enclosure.map { (date: sample.date, value: $0) } }
        report.enclosureTemperatures = thinned(enclosure)
        report.enclosureLow = enclosure.map(\.value).min()
        report.enclosureHigh = enclosure.map(\.value).max()

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
                        if change.date >= cutoff { onsets.append(change) }
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

            let readings = samples.compactMap { sample in sample.drives[bay].map { (date: sample.date, value: $0) } }
            analysis.temperatures = thinned(readings)
            analysis.temperatureLow = readings.map(\.value).min()
            analysis.temperatureHigh = readings.map(\.value).max()
            if latest.statusCode != 0x80 { analysis.temperatureNow = readings.last?.value }
            report.bays.append(analysis)
        }

        // Temperature at each flagging. A drive that has just been dropped may report none, so
        // fall back on the last sample from shortly before.
        for onset in onsets {
            let near = file.samples.last { $0.date <= onset.date && onset.date.timeIntervalSince($0.date) <= 900 }
            guard let temperature = onset.temperature ?? near?.drives[onset.bay] else { continue }
            var reading = FaultReading(bay: onset.bay, date: onset.date, temperature: temperature)
            reading.usual = median(samples.compactMap { $0.drives[onset.bay] })
            reading.others = near.flatMap { sample in median(sample.drives.filter { $0.key != onset.bay }.map(\.value)) }
            report.faultReadings.append(reading)
        }
        let hot = report.faultReadings.filter(\.isHot)
        if let worst = hot.max(by: { $0.temperature < $1.temperature }) {
            report.heatSuspected = true
            var detail: [String] = []
            if let usual = worst.usual, usual != worst.temperature { detail.append("usually \(usual) °C") }
            if let others = worst.others { detail.append("the other drives were at \(others) °C") }
            report.heatNote = "Heat may be involved. \(bayList([worst.bay])) was at \(worst.temperature) °C when it was flagged"
                + (detail.isEmpty ? "." : " (" + detail.joined(separator: "; ") + ").")
            if hot.count > 1 { report.heatNote += " \(hot.count) of \(report.faultReadings.count) flaggings happened hot." }
        } else if !report.faultReadings.isEmpty {
            let values = report.faultReadings.map(\.temperature)
            let low = values.min() ?? 0, high = values.max() ?? 0
            let range = low == high ? "\(low) °C" : "\(low)–\(high) °C"
            let count = report.faultReadings.count
            report.heatNote = "Heat looks unlikely. \(count == 1 ? "The flagged drive was" : "Flagged drives were") at \(range) when flagged, no hotter than usual and no hotter than the other drives."
        }
        // Whatever the faults say, a drive that is hot right now is worth knowing about.
        if let latest = samples.last, now.timeIntervalSince(latest.date) < 1800,
           let hottest = latest.drives.max(by: { $0.value < $1.value }), hottest.value >= hotDrive {
            report.heatSuspected = true
            report.heatNote += (report.heatNote.isEmpty ? "" : " ")
                + "\(bayList([hottest.key])) is at \(hottest.value) °C now. Most drives are rated to about 60 °C; check the fans and vents."
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
        // Flagged bays that all hold the same drive model, when the healthy bays hold others:
        // the model is then as good a suspect as the enclosure.
        let models = Set(troubled.map { $0.model.trimmingCharacters(in: .whitespaces) })
        if troubled.count >= 2, models.count == 1, let model = models.first, !model.isEmpty {
            let others = report.bays.filter { $0.episodes.isEmpty && $0.verdict != .empty }
            if !others.contains(where: { $0.model.trimmingCharacters(in: .whitespaces) == model }) {
                report.sharedModel = model
                report.advice += " All of the flagged bays hold the same model (\(model)) and no healthy bay does. A model the Drobo does not get on with, for example a shingled (SMR) drive that stalls during a rebuild, fits this as well as an enclosure fault does."
            }
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
        // Temperatures: a daily swing, with bay 5 running warm before each time it was flagged.
        let flagged = [-9.9, -6.6, -3.5]
        for step in stride(from: -13.5 * day, through: 0, by: 3600) {
            let offset = step / day
            let swing = sin(offset * 2 * .pi) * 2
            var entry = ThermalSample(date: now.addingTimeInterval(step), enclosure: Int((31 + swing).rounded()), fans: [3, 3])
            for bay in 0..<6 {
                var value = 33 + Double((bay * 7) % 9) + swing
                if bay == 4, flagged.contains(where: { offset > $0 - 0.5 && offset < $0 + 0.3 }) { value += 12 }
                entry.drives[bay] = Int(value.rounded())
            }
            file.samples.append(entry)
        }
        for index in file.changes.indices where file.changes[index].isFault {
            let change = file.changes[index]
            file.changes[index].temperature = file.samples.last { $0.date <= change.date }?.drives[change.bay]
        }
        return file
    }
}
