import Foundation
import IOKit

/// One line of the Drobo's own event log.
///
/// The Drobo keeps this log itself, across restarts and whether or not a computer is attached.
/// Each line is a timestamp, an event number and `KEY=value` details (protocol notes 11.17).
/// The descriptions below are this project's wording for the event numbers Drobo Dashboard knew.
struct DroboLogEntry: Identifiable {
    let id: Int
    let stamp: String
    let date: Date?
    let code: Int
    let parameters: [(key: String, value: String)]

    /// 0 routine, 1 notable, 2 warning: Drobo Dashboard's own grading.
    var severity: Int { DroboLog.table[code]?.severity ?? 0 }
    var isKnown: Bool { DroboLog.table[code] != nil }

    var text: String {
        guard var text = DroboLog.table[code]?.text else {
            let details = parameters.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            return "Event \(code)" + (details.isEmpty ? "" : ": " + details)
        }
        var unused: [String] = []
        if let slot = slot {
            text = text.replacingOccurrences(of: "Bay {SLOT_NUMBER}", with: DroboLog.bayName(slot))
        }
        for parameter in parameters {
            let token = "{" + parameter.key + "}"
            if parameter.key == "SLOT_NUMBER", slot != nil, !text.contains(token) { continue }
            if text.contains(token) {
                text = text.replacingOccurrences(of: token, with: parameter.value)
            } else {
                unused.append("\(parameter.key)=\(parameter.value)")
            }
        }
        return unused.isEmpty ? text : text + " (" + unused.joined(separator: ", ") + ")"
    }

    /// The bay the event names, as the Drobo numbers it.
    var bay: String? { parameters.first { $0.key == "SLOT_NUMBER" }?.value }

    /// The same as a number. The Drobo counts bays from 0, the way the status pages do: an 8D's
    /// log lists bays 0 to 8, and 8 held the cache SSD (seen 2026-11-17).
    var slot: Int? { bay.flatMap { Int($0) } }

    func value(_ key: String) -> String? { parameters.first { $0.key == key }?.value }
}

enum DroboLog {
    /// Entries the hourly check raises as critical, whatever Dashboard graded them: overheating,
    /// a failed or missing drive, a forced restart.
    static let critical: Set<Int> = [212, 216, 219, 228, 229, 232, 655]

    static let table: [Int: (severity: Int, text: String)] = [
        100: (0, "Powered on. Firmware {VERSION}"),
        101: (1, "Powered off with the switch"),
        102: (0, "Restarted"),
        103: (2, "Lost power unexpectedly"),
        104: (2, "Internal error detected"),
        105: (0, "Ran on its backup battery for {TIME} (longest {MAX_TIME}, total {TOTAL_TIME}, {CYCLES} cycles)"),
        106: (0, "Shut down safely on request"),
        125: (0, "Uptime {UPTIME}. Free {FREE_SPACE} ({FREE_PERC}%), used {USED_SPACE} ({USED_PERC}%)"),
        200: (0, "Bay {SLOT_NUMBER}: drive inserted"),
        201: (1, "Bay {SLOT_NUMBER}: drive removed"),
        204: (1, "Bay {SLOT_NUMBER}: the Drobo power-cycled the drive"),
        210: (2, "Bay {SLOT_NUMBER}: error while the drive was being inserted"),
        211: (2, "Bay {SLOT_NUMBER}: drive error (channel failure)"),
        212: (2, "Bay {SLOT_NUMBER}: drive not detected, and too many drives are missing"),
        216: (1, "Bay {SLOT_NUMBER}: drive reached a critical temperature ({DISK_TEMP} °C)"),
        217: (2, "Bay {SLOT_NUMBER}: drive unusable because of bad blocks"),
        218: (2, "Bay {SLOT_NUMBER}: drive failed qualification and cannot be used"),
        219: (2, "A drive the disk pack needs is missing; cannot load"),
        221: (2, "Drives from more than one disk pack are present; cannot load"),
        222: (0, "Bay {SLOT_NUMBER} holds {SERIAL_NUMBER}, {CAPACITY}"),
        223: (0, "Bay {SLOT_NUMBER}: adding {SERIAL_NUMBER} to the disk pack, {CAPACITY}"),
        224: (2, "Bay {SLOT_NUMBER}: could not add {SERIAL_NUMBER} to the disk pack"),
        225: (0, "Bay {SLOT_NUMBER}: {SERIAL_NUMBER} is in use as the cache drive"),
        227: (2, "Disk pack layout not understood by this Drobo or firmware"),
        228: (2, "Restarted because a required drive is missing"),
        229: (2, "Bay {SLOT_NUMBER}: drive {SERIAL_NUMBER} has failed"),
        230: (0, "Drive spin-down turned off"),
        231: (0, "Drive spin-down set to {MINUTES} minutes"),
        232: (2, "Bay {SLOT_NUMBER}: a critical drive was power-cycled, which forced a restart"),
        233: (2, "Bay {SLOT_NUMBER}: drive caused a large drop in write performance"),
        500: (1, "Volume {LUN_NUMBER} deleted"),
        501: (0, "Volume {LUN_NUMBER}: space reclaimed"),
        502: (2, "Volume {LUN_NUMBER}: unsupported block size {BLOCK_SIZE}"),
        503: (0, "Volume {LUN_NUMBER}: being created, {SIZE}"),
        504: (2, "Volume {LUN_NUMBER}: could not be created, {SIZE}"),
        505: (0, "Volume {LUN_NUMBER}: created, {SIZE}"),
        506: (0, "Backup volume {LUN_NUMBER}: created, {SIZE}"),
        520: (0, "Volume {LUN_NUMBER}: {FS_TYPE} file system created"),
        521: (0, "Volume {LUN_NUMBER}: {FS_TYPE} file system found"),
        522: (1, "Volume {LUN_NUMBER}: {FS_TYPE} file system deleted"),
        540: (1, "Volume {LUN_NUMBER}: unhealthy {PARTITION_TYPE} partition at {LBA} ignored"),
        610: (0, "Metadata health check started"),
        611: (0, "Metadata health check resumed"),
        612: (0, "Metadata health check finished"),
        650: (0, "New disk pack created on request"),
        651: (0, "Disk pack renamed from {PREVIOUS_NAME} to {NEW_NAME}"),
        652: (0, "Diagnostics uploaded"),
        653: (0, "Firmware update started"),
        654: (0, "Dual disk redundancy turned on"),
        655: (2, "Shut down to protect data: temperature very high"),
        656: (0, "Dual disk redundancy turned off"),
        657: (0, "New disk pack created automatically"),
        670: (1, "Data protection (rebuild) started"),
        671: (0, "Data protection (rebuild) finished"),
    ]

    static func bayName(_ slot: Int) -> String { slot < 8 ? "Bay \(slot + 1)" : "SSD bay" }

    /// The Drobo prints times like C's ctime. Drobo Dashboard reads them as Pacific time.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    static func parse(_ data: Data) -> [DroboLogEntry] {
        let text = String(decoding: data, as: UTF8.self)
        var entries: [DroboLogEntry] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let characters = Array(line)
            guard characters.count > 26, characters[24] == ":", characters[25] == " " else { continue }
            let stamp = String(characters[0..<24])
            let event = String(characters[26...])
            guard let colon = event.firstIndex(of: ":"), let code = Int(event[..<colon].trimmingCharacters(in: .whitespaces)) else { continue }
            var parameters: [(key: String, value: String)] = []
            for pair in event[event.index(after: colon)...].split(separator: ",") {
                guard let equals = pair.firstIndex(of: "=") else { continue }
                let key = pair[..<equals].trimmingCharacters(in: .whitespaces)
                var value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                // The 8D wraps every value in double quotes.
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                }
                if !key.isEmpty { parameters.append((key, value)) }
            }
            let tidy = stamp.split(separator: " ").joined(separator: " ")
            entries.append(DroboLogEntry(id: entries.count, stamp: tidy, date: formatter.date(from: tidy), code: code, parameters: parameters))
        }
        return entries
    }

    /// Newest first when the times parse; otherwise the Drobo's order reversed.
    static func newestFirst(_ entries: [DroboLogEntry]) -> [DroboLogEntry] {
        if entries.allSatisfy({ $0.date != nil }) {
            return entries.sorted { ($0.date ?? .distantPast, $0.id) > ($1.date ?? .distantPast, $1.id) }
        }
        return entries.reversed()
    }

    /// Copies the log the driver read last out of the driver, 4 KiB at a time. Sends nothing to
    /// the Drobo.
    static func fetch(length: Int) -> Data? {
        guard length > 0, let service = DroboMonitor.driverService() else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }
        var data = Data()
        while data.count < length {
            var offset = UInt32(data.count).littleEndian
            var slice = [UInt8](repeating: 0, count: 4096)
            var size = slice.count
            let result = IOConnectCallStructMethod(connection, 1, &offset, MemoryLayout<UInt32>.size, &slice, &size)
            guard result == KERN_SUCCESS, size > 0 else { break }
            data.append(contentsOf: slice[0..<min(size, slice.count)])
        }
        return data.isEmpty ? nil : data
    }

    static let demo = """
    Sat Mar 14 10:02:11 2026: 100:VERSION="1.2.3"
    Sat Mar 14 10:02:30 2026: 222:SLOT_NUMBER="4",SERIAL_NUMBER="DEMO0907",CAPACITY="3.63TiB"
    Sat Mar 14 10:02:30 2026: 222:SLOT_NUMBER="5",SERIAL_NUMBER="DEMO2210",CAPACITY="7.27TiB"
    Sat Mar 14 10:09:00 2026: 125:UPTIME="6Mins:49Secs",FREE_SPACE="16.90TiB",FREE_PERC="78.24",USED_SPACE="4.70TiB",USED_PERC="21.76"
    Wed Apr 08 12:00:00 2026: 610:
    Wed Apr 08 12:21:40 2026: 612:ELAPSED_TIME="21Mins:40Secs",MEBIBYTES_PER_SECOND="198 MiB/s",NUM_ZONES_SCRUBBED="240"
    Fri May 01 10:09:00 2026: 125:UPTIME="48Days",FREE_SPACE="15.80TiB",FREE_PERC="73.15",USED_SPACE="5.80TiB",USED_PERC="26.85"
    Tue Jun 16 03:11:52 2026: 103:
    Tue Jun 16 03:11:52 2026: 100:VERSION="1.2.3"
    Wed Jul 01 03:20:00 2026: 125:UPTIME="15Days",FREE_SPACE="15.10TiB",FREE_PERC="69.91",USED_SPACE="6.50TiB",USED_PERC="30.09"
    Sat Aug 08 12:00:00 2026: 610:
    Sat Aug 08 12:31:05 2026: 612:ELAPSED_TIME="31Mins:5Secs",MEBIBYTES_PER_SECOND="141 MiB/s",NUM_ZONES_SCRUBBED="262"
    Tue Sep 01 03:20:00 2026: 125:UPTIME="77Days",FREE_SPACE="14.60TiB",FREE_PERC="67.59",USED_SPACE="7.00TiB",USED_PERC="32.41"
    Mon Nov 02 08:14:02 2026: 100:VERSION="1.2.3"
    Mon Nov 02 08:14:20 2026: 222:SLOT_NUMBER="4",SERIAL_NUMBER="DEMO1548",CAPACITY="3.63TiB"
    Mon Nov 02 08:14:21 2026: 223:SLOT_NUMBER="4",SERIAL_NUMBER="DEMO1548",CAPACITY="3.63TiB"
    Mon Nov 02 08:14:25 2026: 670:
    Tue Nov 03 19:40:02 2026: 671:
    Sat Nov 07 02:41:10 2026: 211:SLOT_NUMBER="4"
    Sat Nov 07 02:41:12 2026: 204:SLOT_NUMBER="4"
    Sat Nov 07 02:44:51 2026: 233:SLOT_NUMBER="4"
    Sat Nov 07 02:50:03 2026: 229:SLOT_NUMBER="4",SERIAL_NUMBER="DEMO1548"
    Sat Nov 07 02:50:04 2026: 670:
    Sat Nov 07 09:12:40 2026: 102:
    Sat Nov 07 09:13:05 2026: 100:VERSION="1.2.3"
    Sat Nov 07 09:13:30 2026: 223:SLOT_NUMBER="4",SERIAL_NUMBER="DEMO1548",CAPACITY="3.63TiB"
    Tue Nov 10 03:02:11 2026: 211:SLOT_NUMBER="5"
    Tue Nov 10 03:02:15 2026: 232:SLOT_NUMBER="5"
    Tue Nov 10 03:03:00 2026: 100:VERSION="1.2.3"
    Fri Nov 13 21:30:44 2026: 671:
    Fri Nov 13 21:31:00 2026: 125:UPTIME="3Days:18Hours",FREE_SPACE="14.20TiB",FREE_PERC="65.74",USED_SPACE="7.40TiB",USED_PERC="34.26"
    Sat Nov 14 11:05:09 2026: 9999:FOO="bar"

    """
}


// MARK: What the log adds up to

/// One drive's stay in a bay, as the log's "Bay n holds <serial>" lines show it.
struct DroboLogDrive {
    let serial: String
    let capacity: String
    let firstSeen: Date
    var lastSeen: Date
}

struct DroboLogBay: Identifiable {
    let slot: Int
    var id: Int { slot }
    var name: String { DroboLog.bayName(slot) }
    /// Oldest first. More than one means the drive was swapped.
    var drives: [DroboLogDrive] = []
    /// Everything the Drobo logged against this bay apart from the routine roll call, newest first.
    var problems: [DroboLogEntry] = []

    /// "2 drive errors, 1 failure" style count of the problems, most serious first.
    var problemText: String {
        var counts: [Int: Int] = [:]
        for entry in problems { counts[entry.code, default: 0] += 1 }
        let order = [229, 217, 218, 232, 216, 233, 211, 210, 212, 224, 204, 201]
        var parts: [String] = []
        for code in order + counts.keys.filter({ !order.contains($0) }).sorted() {
            guard let count = counts[code] else { continue }
            parts.append("\(count)× \(DroboLogSummary.short[code] ?? "event \(code)")")
        }
        return parts.joined(separator: ", ")
    }
}

struct DroboLogSummary {
    var count = 0
    var first: Date?
    var last: Date?
    /// Used space as the Drobo logged it about once a day, oldest first.
    var capacity: [(date: Date, usedBytes: Double, usedPercent: Double)] = []
    var powerLosses: [Date] = []
    var internalErrors: [Date] = []
    var overheating: [DroboLogEntry] = []
    var powerOns = 0
    /// Rebuilds, oldest first. `end` is nil for one that never logged a finish.
    var rebuilds: [(start: Date, end: Date?)] = []
    /// The Drobo's periodic metadata check, with the speed it reported, oldest first.
    var healthChecks: [(date: Date, speed: Int, elapsed: String)] = []
    var bays: [DroboLogBay] = []
    var firmware = ""

    static let short: [Int: String] = [
        201: "removed", 204: "power-cycled by the Drobo", 210: "insert error", 211: "drive error",
        212: "not detected", 216: "critical temperature", 217: "bad blocks", 218: "failed qualification",
        224: "could not be added", 229: "marked failed", 232: "forced a restart", 233: "slowed writes",
    ]

    var isEmpty: Bool { count == 0 }

    /// Health-check speed now against the best it ever logged; nil without two checks.
    var healthTrend: (latest: Int, best: Int)? {
        guard healthChecks.count > 1, let latest = healthChecks.last?.speed, let best = healthChecks.map(\.speed).max(), best > 0 else { return nil }
        return (latest, best)
    }

    var longestRebuild: TimeInterval? {
        rebuilds.compactMap { rebuild in rebuild.end.map { $0.timeIntervalSince(rebuild.start) } }.max()
    }

    /// "2.59TiB", "931.00GiB", "0B" as bytes.
    static func bytes(_ text: String) -> Double? {
        let units: [(String, Double)] = [("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024),
                                         ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for (suffix, scale) in units where trimmed.hasSuffix(suffix) {
            return Double(trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)).map { $0 * scale }
        }
        return nil
    }

    static func make(_ entries: [DroboLogEntry]) -> DroboLogSummary {
        var summary = DroboLogSummary()
        let ordered = entries.filter { $0.date != nil }.sorted { ($0.date!, $0.id) < ($1.date!, $1.id) }
        summary.count = entries.count
        summary.first = ordered.first?.date
        summary.last = ordered.last?.date
        var bays: [Int: DroboLogBay] = [:]
        var open: Date?
        for entry in ordered {
            guard let date = entry.date else { continue }
            switch entry.code {
            case 100:
                summary.powerOns += 1
                if let version = entry.value("VERSION") { summary.firmware = version }
            case 103: summary.powerLosses.append(date)
            case 104: summary.internalErrors.append(date)
            case 216, 655: summary.overheating.append(entry)
            case 125:
                if let used = entry.value("USED_SPACE").flatMap(bytes), let percent = entry.value("USED_PERC").flatMap(Double.init) {
                    summary.capacity.append((date, used, percent))
                }
            case 670:
                // A restart mid-rebuild logs a second start; keep the first.
                if open == nil { open = date }
            case 671:
                if let start = open { summary.rebuilds.append((start, date)) }
                open = nil
            case 612:
                let digits = (entry.value("MEBIBYTES_PER_SECOND") ?? "").prefix { $0.isNumber }
                if let speed = Int(digits) { summary.healthChecks.append((date, speed, entry.value("ELAPSED_TIME") ?? "")) }
            default: break
            }
            guard let slot = entry.slot else { continue }
            var bay = bays[slot] ?? DroboLogBay(slot: slot)
            if entry.code == 222 || entry.code == 223 || entry.code == 225, let serial = entry.value("SERIAL_NUMBER") {
                if let index = bay.drives.indices.last, bay.drives[index].serial == serial {
                    bay.drives[index].lastSeen = date
                } else {
                    bay.drives.append(DroboLogDrive(serial: serial, capacity: entry.value("CAPACITY") ?? "", firstSeen: date, lastSeen: date))
                }
            } else if entry.code != 200 {
                bay.problems.insert(entry, at: 0)
            }
            bays[slot] = bay
        }
        if let start = open { summary.rebuilds.append((start, nil)) }
        summary.bays = bays.values.sorted { $0.slot < $1.slot }
        return summary
    }

    /// 3725 seconds as "1h 2m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }
        if minutes < 48 * 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d \((minutes % 1440) / 60)h"
    }

    /// Plain lines for the command line and for copying.
    func lines(now: Date = Date()) -> [String] {
        guard let first, let last else { return ["The log holds no dated events."] }
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted)
        var lines = ["\(count) events, \(first.formatted(day)) to \(last.formatted(day))." + (firmware.isEmpty ? "" : " Firmware \(firmware).")]
        if let low = capacity.first, let high = capacity.last {
            let peak = capacity.map(\.usedPercent).max() ?? high.usedPercent
            lines.append(String(format: "Used space: %.0f%% then, %.0f%% at the end, peak %.0f%%.", low.usedPercent, high.usedPercent, peak))
        }
        func dated(_ label: String, _ dates: [Date]) -> String {
            dates.isEmpty ? "\(label): none." : "\(label): \(dates.count), last \(dates.last!.formatted(day))."
        }
        lines.append(dated("Unexpected power losses", powerLosses))
        lines.append(dated("Internal errors", internalErrors))
        lines.append(overheating.isEmpty ? "Overheating events: none."
                     : "Overheating events: \(overheating.count), last \(overheating.last?.date?.formatted(day) ?? "?") (\(overheating.last?.text ?? "")).")
        if rebuilds.isEmpty {
            lines.append("Rebuilds: none.")
        } else {
            var text = "Rebuilds: \(rebuilds.count)"
            if let longest = longestRebuild { text += ", longest \(Self.duration(longest))" }
            if let latest = rebuilds.last {
                text += latest.end == nil ? ", one started \(latest.start.formatted(day)) has not logged a finish"
                                          : ", last finished \(latest.end!.formatted(day))"
            }
            lines.append(text + ".")
        }
        if let latest = healthChecks.last {
            var text = "Metadata health check: \(latest.speed) MiB/s on \(latest.date.formatted(day))"
            if let trend = healthTrend, trend.latest < trend.best { text += ", best \(trend.best) MiB/s" }
            lines.append(text + ".")
        }
        for bay in bays {
            var text = "\(bay.name): "
            if let drive = bay.drives.last {
                text += "\(drive.capacity) drive since \(drive.firstSeen.formatted(day))"
                if bay.drives.count > 1 { text += " (\(bay.drives.count - 1) earlier)" }
            } else {
                text += "no drive listed"
            }
            text += bay.problems.isEmpty ? ". Nothing logged against it."
                : ". \(bay.problemText); last \(bay.problems.first?.date?.formatted(day) ?? "?")."
            lines.append(text)
        }
        return lines
    }
}
