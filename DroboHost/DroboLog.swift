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
        for parameter in parameters {
            let token = "{" + parameter.key + "}"
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
                let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
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
    Mon Nov  2 08:14:02 2026: 100:VERSION=1.2.3
    Mon Nov  2 08:14:20 2026: 222:SLOT_NUMBER=5,SERIAL_NUMBER=DEMO1548,CAPACITY=4 TB
    Sat Nov  7 02:41:10 2026: 211:SLOT_NUMBER=5
    Sat Nov  7 02:41:12 2026: 204:SLOT_NUMBER=5
    Sat Nov  7 02:44:51 2026: 233:SLOT_NUMBER=5
    Sat Nov  7 02:50:03 2026: 229:SLOT_NUMBER=5,SERIAL_NUMBER=DEMO1548
    Sat Nov  7 02:50:04 2026: 670:
    Sat Nov  7 09:12:40 2026: 102:
    Sat Nov  7 09:13:05 2026: 100:VERSION=1.2.3
    Sat Nov  7 09:13:30 2026: 223:SLOT_NUMBER=5,SERIAL_NUMBER=DEMO1548,CAPACITY=4 TB
    Tue Nov 10 03:02:11 2026: 211:SLOT_NUMBER=6
    Tue Nov 10 03:02:15 2026: 232:SLOT_NUMBER=6
    Tue Nov 10 03:03:00 2026: 100:VERSION=1.2.3
    Fri Nov 13 21:30:44 2026: 671:
    Fri Nov 13 21:31:00 2026: 125:UPTIME=3d 18h,FREE_SPACE=14.2 TB,FREE_PERC=66,USED_SPACE=7.4 TB,USED_PERC=34
    Sat Nov 14 11:05:09 2026: 9999:FOO=bar

    """
}
