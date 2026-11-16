import Foundation
import os.log

/// One line in the Events tab.
struct DroboEvent: Codable, Identifiable {
    enum Level: String, Codable { case info, good, warning, critical }
    var id = UUID()
    let date: Date
    let level: Level
    let title: String
    var detail = ""
}

/// What happened to the Drobo while the app was watching: status alerts appearing and clearing,
/// drives changing state, the unit restarting, volumes mounting. Built by comparing each poll
/// with the one before it, so it only covers time the app (or its menu bar item) was running.
/// Kept in Application Support, newest first, capped.
final class EventLog: ObservableObject {
    @Published private(set) var events: [DroboEvent] = []

    /// Called once per poll with the events that poll produced, for notifications and webhooks.
    var onChanges: (([DroboEvent]) -> Void)?

    /// Every event also goes to the macOS log, so Console and `log show` can report on it:
    ///   log show --last 1d --predicate 'subsystem == "com.joemattiello.DroboDriverKit" AND category == "events"'
    private static let systemLog = Logger(subsystem: "com.joemattiello.DroboDriverKit", category: "events")

    private let persist: Bool
    private let limit = 1000
    private var primed = false
    private var batch: [DroboEvent]?

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("DroboDriverKit", isDirectory: true).appendingPathComponent("events.json")
    }

    init(persist: Bool) {
        self.persist = persist
        guard persist, let url = Self.fileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = (try? decoder.decode([DroboEvent].self, from: data)) ?? []
    }

    func add(_ level: DroboEvent.Level, _ title: String, _ detail: String = "", date: Date = Date()) {
        let event = DroboEvent(date: date, level: level, title: title, detail: detail)
        if persist {
            let line = detail.isEmpty ? title : "\(title): \(detail)"
            switch level {
            case .critical: Self.systemLog.fault("\(line, privacy: .public)")
            case .warning: Self.systemLog.error("\(line, privacy: .public)")
            case .good, .info: Self.systemLog.notice("\(line, privacy: .public)")
            }
        }
        batch?.append(event)
        events.insert(event, at: 0)
        if events.count > limit { events.removeLast(events.count - limit) }
        save()
    }

    func clear() {
        events = []
        save()
    }

    private func save() {
        guard persist, let url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Compares two consecutive polls and records what changed.
    func observe(previous: DroboSnapshot, latest: DroboSnapshot, previousLUNs: [DroboLUN], latestLUNs: [DroboLUN]) {
        batch = []
        compare(previous: previous, latest: latest, previousLUNs: previousLUNs, latestLUNs: latestLUNs)
        let produced = batch ?? []
        batch = nil
        if !produced.isEmpty { onChanges?(produced) }
    }

    /// The conditions already in force when the Drobo comes (back) up. Without this they would
    /// never be logged, because only changes between two ready polls are compared.
    private func recordStanding(_ snapshot: DroboSnapshot) {
        let flags = snapshot.statusFlags ?? 0
        for (bit, text) in DroboSnapshot.statusTable where flags & bit != 0 && !text.hasPrefix("Status bit") {
            add(bit & 0x0132 != 0 ? .critical : .warning, text, "Already active when the Drobo came up.")
        }
        // One line per drive state rather than one per bay: a rebuild marks every bay at once.
        let unhealthy = snapshot.slots.filter { !$0.isEmpty && $0.statusCode & 0x0F != 3 }
        for status in Set(unhealthy.map(\.statusText)).sorted() {
            let bays = unhealthy.filter { $0.statusText == status }.map { $0.id < 8 ? "\($0.id + 1)" : "SSD" }
            let failed = status.hasPrefix("Failed")
            add(failed ? .critical : .warning, "\(bays.count == 1 ? "Bay" : "Bays") \(bays.joined(separator: ", ")): \(status)",
                "Already in this state when the Drobo came up.")
        }
    }

    private func compare(previous: DroboSnapshot, latest: DroboSnapshot, previousLUNs: [DroboLUN], latestLUNs: [DroboLUN]) {
        let name = latest.name.isEmpty ? "Drobo" : latest.name
        guard primed else {
            primed = true
            let state = !latest.driverPresent ? "The driver is not running."
                : !latest.ready ? "The Drobo is still starting."
                : latest.statusLines.filter { !$0.hasPrefix("Status bit") }.joined(separator: ". ")
            add(.info, "Monitoring started", state)
            return
        }

        if previous.driverPresent != latest.driverPresent {
            if latest.driverPresent {
                add(.info, "Driver connected")
            } else {
                add(.warning, "Drobo disconnected", "The driver is no longer attached. Check power and the Thunderbolt cable.")
            }
        }
        if previous.ready != latest.ready, latest.driverPresent {
            if latest.ready {
                add(.good, "\(name) is ready")
            } else if previous.driverPresent {
                add(.warning, "\(name) stopped responding", "The Drobo restarted or is starting up again.")
            }
        }
        // The status pages arrive a few seconds after the Drobo reports ready, so "what is already
        // wrong" is recorded when the first status is in, not at the ready transition itself.
        if latest.ready, latest.statusFlags != nil, previous.statusFlags == nil || !previous.ready {
            recordStanding(latest)
            return
        }
        guard previous.ready, latest.ready else { return }

        if let old = previous.statusFlags, let new = latest.statusFlags, old != new {
            for (bit, text) in DroboSnapshot.statusTable where !text.hasPrefix("Status bit") {
                if new & bit != 0, old & bit == 0 {
                    add(bit & 0x0132 != 0 ? .critical : .warning, text)
                } else if new & bit == 0, old & bit != 0 {
                    add(.good, "Cleared: " + text)
                }
            }
        }

        for slot in latest.slots {
            guard let before = previous.slots.first(where: { $0.id == slot.id }), before.statusCode != slot.statusCode else { continue }
            let bay = slot.id < 8 ? "Bay \(slot.id + 1)" : "SSD bay"
            if before.isEmpty {
                add(.info, "\(bay): drive inserted", "\(DashboardModel.bytes(slot.physicalBytes)) \(slot.model)")
            } else if slot.isEmpty {
                add(.warning, "\(bay): drive removed", before.model)
            } else {
                let code = slot.statusCode & 0x0F
                let level: DroboEvent.Level = code == 3 ? .good : (code == 1 || code == 6 ? .critical : .warning)
                add(level, "\(bay): \(before.statusText) → \(slot.statusText)", slot.model)
            }
        }

        for slot in latest.slots {
            guard let now = slot.errorCount, let before = previous.slots.first(where: { $0.id == slot.id })?.errorCount,
                  now > before else { continue }
            add(.warning, "\(slot.id < 8 ? "Bay \(slot.id + 1)" : "SSD bay"): drive error count rose to \(now)", slot.model)
        }

        // The Drobo's own verdict on each drive (good, healed, warning, failed).
        for slot in latest.slots where !slot.isEmpty {
            guard let now = slot.diskStateCode, let text = slot.diskStateText,
                  let before = previous.slots.first(where: { $0.id == slot.id }),
                  let old = before.diskStateCode, let oldText = before.diskStateText, old != now else { continue }
            let level: DroboEvent.Level = now >= 3 ? .critical : (now >= 1 ? .warning : .good)
            add(level, "\(slot.id < 8 ? "Bay \(slot.id + 1)" : "SSD bay"): drive state \(oldText) → \(text)", slot.model)
        }

        if latest.errors > previous.errors {
            add(.warning, "The driver reported \(latest.errors - previous.errors) I/O error(s)", "Total since it started: \(latest.errors).")
        }

        let before = Set(previousLUNs.flatMap(\.volumeNames))
        let after = Set(latestLUNs.flatMap(\.volumeNames))
        for volume in after.subtracting(before).sorted() { add(.info, "Mounted \(volume)") }
        for volume in before.subtracting(after).sorted() { add(.info, "Unmounted \(volume)") }
    }
}

/// One point of performance history.
struct PerformanceSample: Identifiable {
    let date: Date
    let readRate: Double            // bytes per second
    let writeRate: Double
    let blocksLeft: UInt32          // rebuild blocks remaining, 0 when not rebuilding
    var id: Date { date }
}

/// Throughput and rebuild progress over time, sampled from each poll while the app is running.
/// In memory only: the last hour at full resolution and the last 24 hours as one-minute averages.
final class PerformanceHistory: ObservableObject {
    @Published private(set) var recent: [PerformanceSample] = []      // every poll, up to an hour
    @Published private(set) var minutes: [PerformanceSample] = []     // one per minute, up to a day

    private let recentLimit = 1800
    private let minuteLimit = 1440
    private var bucket: (start: Date, read: Double, write: Double, count: Double)?

    func record(date: Date, readRate: Double, writeRate: Double, blocksLeft: UInt32) {
        recent.append(PerformanceSample(date: date, readRate: readRate, writeRate: writeRate, blocksLeft: blocksLeft))
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }

        if var current = bucket, date.timeIntervalSince(current.start) < 60 {
            current.read += readRate
            current.write += writeRate
            current.count += 1
            bucket = current
        } else {
            if let done = bucket, done.count > 0 {
                minutes.append(PerformanceSample(date: done.start, readRate: done.read / done.count,
                                                 writeRate: done.write / done.count, blocksLeft: blocksLeft))
                if minutes.count > minuteLimit { minutes.removeFirst(minutes.count - minuteLimit) }
            }
            bucket = (date, readRate, writeRate, 1)
        }
    }

    /// Samples covering the last `seconds`, from whichever series has the right resolution.
    func samples(last seconds: TimeInterval, now: Date = Date()) -> [PerformanceSample] {
        let source = seconds > 3600 ? minutes : recent
        let cutoff = now.addingTimeInterval(-seconds)
        return source.filter { $0.date >= cutoff }
    }

    /// Made-up history for demo mode.
    func seedDemo(rebuilding: Bool, now: Date = Date()) {
        func wave(_ index: Int, _ base: Double, _ swing: Double, _ period: Double) -> Double {
            let noise = Double((index &* 2_654_435_761) % 1000) / 1000 - 0.5
            return max(0, base + swing * sin(Double(index) / period) + swing * 0.5 * noise)
        }
        recent = (0..<1800).map { index in
            PerformanceSample(date: now.addingTimeInterval(Double(index - 1800) * 2),
                              readRate: wave(index, 78e6, 30e6, 90), writeRate: rebuilding ? 0 : wave(index + 400, 11e6, 9e6, 140),
                              blocksLeft: rebuilding ? UInt32(18_420 + (1800 - index) / 3) : 0)
        }
        minutes = (0..<1440).map { index in
            PerformanceSample(date: now.addingTimeInterval(Double(index - 1440) * 60),
                              readRate: wave(index, 60e6, 45e6, 110), writeRate: rebuilding ? 0 : wave(index + 300, 9e6, 8e6, 200),
                              blocksLeft: rebuilding ? UInt32(18_420 + (1440 - index) * 20) : 0)
        }
    }
}

extension EventLog {
    /// Made-up events for demo mode. Never saved.
    func seedDemo(rebuilding: Bool, now: Date = Date()) {
        typealias Entry = (Double, DroboEvent.Level, String, String)
        var entries: [Entry] = []
        entries.append((-93_600, .info, "Monitoring started", "Healthy"))
        entries.append((-90_000, .info, "Mounted Archive", ""))
        entries.append((-90_000, .info, "Mounted Media", ""))
        entries.append((-32_400, .warning, "Bay 3: Healthy → Warning", "ST8000VN004"))
        entries.append((-18_000, .warning, "Studio Array stopped responding", "The Drobo restarted or is starting up again."))
        entries.append((-17_710, .good, "Studio Array is ready", ""))
        entries.append((-17_700, .warning, "No redundancy: a second failure would lose data", ""))
        entries.append((-17_700, .warning, "Data protection in progress (rebuilding)", ""))
        entries.append((-17_698, .warning, "Bay 3: Warning → Rebuilding", "ST8000VN004"))
        if !rebuilding {
            entries.append((-2_400, .good, "Cleared: Data protection in progress (rebuilding)", ""))
            entries.append((-2_400, .good, "Cleared: No redundancy: a second failure would lose data", ""))
            entries.append((-2_398, .good, "Bay 3: Rebuilding → Healthy", "ST8000VN004"))
        }
        events = entries.map { DroboEvent(date: now.addingTimeInterval($0.0), level: $0.1, title: $0.2, detail: $0.3) }.reversed()
    }
}
