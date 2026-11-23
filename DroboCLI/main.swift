import Foundation

/// `drobo`: status from the command line, for shell prompts, tmux/vim status lines, scripts
/// and dashboards. It reads what the driver publishes (the same source as the app). The only
/// commands that send anything to the Drobo are `volume create`, `volume delete` and `reset`,
/// and only with `--yes-really` and the Drobo's serial number (docs/05-volume-management.md).
///
/// Exit status: 0 healthy, 1 warning or rebuilding, 2 needs attention, 3 not connected,
/// 64 usage error.

let usage = """
usage: drobo [command] [options]

commands
  status                 one-line summary (default)
  device                 name, serial, firmware, capacity, protection, alerts
  drives                 every bay
  drive <bay>            one bay (1-8, or ssd)
  volumes                every volume
  volume <name|lun>      one volume, by mounted name or unit number
  all                    device, drives and volumes
  get <key>              one bare value, for scripts and status lines
  keys                   list the keys `get` accepts
  log                    the Drobo's own event log, as last read in the app (Events tab, Read from Drobo)
                         --summary: what it adds up to (power losses, rebuilds, each bay's drive and problems)
                         --problems: warnings and notable events only; --bay <1-8|ssd>: one bay's events
  history                each bay over the last 14 days: flagged, recovered, restarts, and what the pattern suggests
  diagnostics            raw driver state and management pages as JSON, serial and name redacted
  metrics                Prometheus text format, for node_exporter's textfile collector, Telegraf, etc.
  speedtest <name|unit>  write and read speed of a mounted volume that allows writes, in MB/s; --size 1GB|5GB|... (default 1GB).
                         Writes one test file, reads it back and removes it; --json for the numbers alone

commands that change the Drobo (each prints what it would do and stops unless --yes-really is given;
all refuse while any Drobo volume is mounted)
  volume create          a new volume; --size <n>TB|<n>GB|max (default max, the largest the Drobo allows)
  volume format <unit>   makes a new, blank volume usable: allows writing to it and puts an empty file system on it
                         --name <name> (required), --fs apfs|hfs (default apfs). Refuses a unit that is not blank
  volume delete <unit>   DELETES that volume and everything in it
  reset                  ERASES every drive in the Drobo and its settings, then the Drobo restarts
                         --volume-size <n>TB: come back with one volume of that size (1, 2, 4, 8, 16, 32, 64 or 128 TB).
                         This is the only way to change a Drobo's volume size; nothing can be resized in place
                         --serial <serial>: the Drobo's serial number (`drobo get serial`), as confirmation;
                         asked for at the prompt when left out
                         --yes-really: actually send it

options
  --json                 machine-readable output (status, device, drives, volumes, all)
  --short                compact status, e.g. "Drobo ok 34%"
  --watch [seconds]      redraw until interrupted (default 2)
  --demo <healthy|rebuilding>   made-up data, no driver needed

exit status: 0 healthy, 1 warning or rebuilding, 2 needs attention, 3 not connected
(volume create, volume delete, reset: 0 done, 1 refused or failed, 2 nothing sent because --yes-really was missing)
"""

// MARK: Drive history

func historyJSON(_ report: BayReport) -> [String: Any] {
    let stamp = ISO8601DateFormatter()
    var bays: [[String: Any]] = []
    for bay in report.bays {
        var episodes: [[String: Any]] = []
        for episode in bay.episodes {
            var entry: [String: Any] = ["start": stamp.string(from: episode.start), "clearedByRestart": episode.clearedByRestart]
            if let end = episode.end { entry["end"] = stamp.string(from: end) }
            episodes.append(entry)
        }
        var entry: [String: Any] = ["bay": bay.bay < 8 ? "\(bay.bay + 1)" : "ssd", "model": bay.model]
        entry["verdict"] = bay.verdict.rawValue
        entry["summary"] = bay.summary
        entry["timesFlagged"] = bay.episodes.count
        entry["errorCountRise"] = bay.errorRise
        entry["episodes"] = episodes
        if let low = bay.temperatureLow, let high = bay.temperatureHigh {
            entry["temperatureLow"] = low
            entry["temperatureHigh"] = high
        }
        if let last = bay.temperatureNow { entry["temperatureLast"] = last }
        bays.append(entry)
    }
    var result: [String: Any] = ["days": Int(report.window / 86_400), "bays": bays]
    result["restarts"] = report.restarts.map { stamp.string(from: $0) }
    result["finding"] = report.headline
    result["advice"] = report.advice
    result["enclosureSuspected"] = report.enclosureSuspected
    result["sharedModel"] = report.sharedModel
    result["heat"] = report.heatNote
    result["heatSuspected"] = report.heatSuspected
    if let low = report.enclosureLow, let high = report.enclosureHigh {
        result["enclosureTemperatureLow"] = low
        result["enclosureTemperatureHigh"] = high
    }
    result["flaggings"] = report.faultReadings.map { reading -> [String: Any] in
        var entry: [String: Any] = ["bay": reading.bay < 8 ? "\(reading.bay + 1)" : "ssd", "date": stamp.string(from: reading.date),
                                    "temperature": reading.temperature, "hot": reading.isHot]
        if let usual = reading.usual { entry["usual"] = usual }
        if let others = reading.others { entry["otherDrives"] = others }
        return entry
    }
    return result
}

func historyText(_ report: BayReport) -> String {
    guard !report.bays.isEmpty else {
        return "No drive history yet. It is recorded while the DroboDriverKit app or its menu bar item is running."
    }
    var lines: [String] = []
    if !report.headline.isEmpty {
        lines.append(report.headline + ".")
        lines.append(report.advice)
        lines.append("")
    }
    for bay in report.bays {
        let name = bay.name.padding(toLength: 8, withPad: " ", startingAt: 0)
        let verdict = bay.verdict.label.padding(toLength: 15, withPad: " ", startingAt: 0)
        lines.append(name + verdict + bay.summary + (bay.temperatureText.isEmpty ? "" : " " + bay.temperatureText + "."))
    }
    if !report.heatNote.isEmpty {
        lines.append("")
        lines.append(report.heatNote)
    }
    if let low = report.enclosureLow, let high = report.enclosureHigh {
        lines.append("Enclosure " + (low == high ? "\(low) C" : "\(low)-\(high) C") + " over the same period.")
    }
    let days = Int(report.window / 86_400)
    lines.append("")
    lines.append("Last \(days) days, \(report.restarts.count) Drobo restart(s) seen. Covers only the time the app was running.")
    return lines.joined(separator: "\n")
        .replacingOccurrences(of: " °C", with: " C").replacingOccurrences(of: "–", with: "-")
}

// MARK: State

struct State {
    let snapshot: DroboSnapshot
    let volumes: [DroboVolume]
    let luns: [DroboLUN]

    static func load(demo: String?) -> State {
        if let demo {
            let data = Demo.data(demo)
            return State(snapshot: data.snapshot, volumes: data.volumes, luns: data.luns)
        }
        let snapshot = DroboMonitor.snapshot()
        let volumes = DroboMonitor.volumes()
        return State(snapshot: snapshot, volumes: volumes, luns: DroboMonitor.luns(snapshot, volumes: volumes))
    }

    /// Same thresholds as the app's status pill.
    var health: (word: String, code: Int32) {
        guard snapshot.driverPresent else { return ("not connected", 3) }
        guard snapshot.ready else { return ("starting", 3) }
        guard let flags = snapshot.statusFlags else { return ("checking", 1) }
        if flags & 0x0132 != 0 { return ("needs attention", 2) }
        if snapshot.isRebuilding { return ("rebuilding", 1) }
        if flags & 0x00C4 != 0 { return ("warning", 1) }
        return ("healthy", 0)
    }

    var name: String { snapshot.name.isEmpty ? "Drobo" : snapshot.name }
    var alerts: [String] { snapshot.statusLines.filter { $0 != "Healthy" && !$0.hasPrefix("Status bit") } }
    var capacity: (used: UInt64, total: UInt64)? {
        guard let used = snapshot.usedBytes, let free = snapshot.freeBytes, used + free > 0 else { return nil }
        return (used, used + free)
    }
    var percent: Int? { capacity.map { Int((Double($0.used) / Double($0.total) * 100).rounded()) } }
    var filledBays: Int { snapshot.slots.filter { !$0.isEmpty }.count }

    func slot(_ text: String) -> DroboSlot? {
        if text.lowercased() == "ssd" { return snapshot.slots.first { $0.id == 8 } }
        guard let bay = Int(text), (1...8).contains(bay) else { return nil }
        return snapshot.slots.first { $0.id == bay - 1 }
    }

    func lun(_ text: String) -> DroboLUN? {
        if let match = luns.first(where: { ($0.volumeNames + $0.knownNames).contains { $0.caseInsensitiveCompare(text) == .orderedSame } }) {
            return match
        }
        return Int(text).flatMap { id in luns.first { $0.id == id } }
    }
}

func human(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

func bayLabel(_ slot: DroboSlot) -> String { slot.id < 8 ? "\(slot.id + 1)" : "ssd" }

// MARK: Text output

func table(_ rows: [[String]]) -> String {
    guard let columns = rows.first?.count else { return "" }
    let widths = (0..<columns).map { column in rows.map { $0[column].count }.max() ?? 0 }
    return rows.map { row in
        row.enumerated().map { index, cell in
            index == columns - 1 ? cell : cell.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0)
        }.joined()
    }.joined(separator: "\n")
}

func statusLine(_ state: State, short: Bool) -> String {
    let health = state.health
    if short {
        let word = ["healthy": "ok", "rebuilding": "rebuild", "needs attention": "ALERT", "not connected": "off"][health.word] ?? health.word
        return "Drobo \(word)" + (state.percent.map { " \($0)%" } ?? "")
    }
    guard health.code != 3 else { return "Drobo: \(health.word)" }
    var parts = ["\(state.name): \(health.word)"]
    if state.snapshot.relayoutCount > 0 { parts[0] += " (\(state.snapshot.relayoutCount) blocks left)" }
    if let capacity = state.capacity, let percent = state.percent {
        parts.append("\(human(capacity.used)) of \(human(capacity.total)) used (\(percent)%)")
    }
    parts.append("\(state.filledBays)/\(state.snapshot.slots.count) drives")
    return parts.joined(separator: " · ")
}

func deviceText(_ state: State) -> String {
    let snapshot = state.snapshot
    guard snapshot.ready else { return statusLine(state, short: false) }
    var rows = [
        ["Name", state.name],
        ["Status", state.health.word],
        ["Serial", snapshot.serial],
        ["Firmware", snapshot.firmware],
    ]
    if let capacity = state.capacity, let percent = state.percent {
        rows.append(["Used", "\(human(capacity.used)) (\(percent)%)"])
        rows.append(["Free", human(capacity.total - capacity.used)])
        rows.append(["Protected", human(capacity.total)])
    }
    if let dual = snapshot.dualDiskRedundancy { rows.append(["Redundancy", dual ? "dual disk" : "single disk"]) }
    if let minutes = snapshot.spinDownMinutes { rows.append(["Spin-down", minutes > 0 ? "\(minutes) min" : "off"]) }
    if snapshot.relayoutCount > 0 { rows.append(["Rebuild", "\(snapshot.relayoutCount) blocks left"]) }
    if let temperature = snapshot.systemTemperature { rows.append(["Temperature", "\(temperature) C"]) }
    if let uptime = snapshot.uptime, uptime > 0 { rows.append(["Uptime", "\(uptime / 86_400)d \(uptime % 86_400 / 3600)h \(uptime % 3600 / 60)m"]) }
    if !snapshot.fanLevels.isEmpty { rows.append(["Fans", snapshot.fanLevels.map { "level \($0)" }.joined(separator: ", ")]) }
    for alert in state.alerts { rows.append(["Alert", alert]) }
    return table(rows)
}

func drivesText(_ slots: [DroboSlot]) -> String {
    guard !slots.isEmpty else { return "No bay information." }
    // Speed, life, errors and firmware appear only when drive details are on (see the app).
    let detailed = slots.contains { $0.errorCount != nil }
    let warm = slots.contains { $0.temperature != nil }

    var header: [String] = ["BAY", "SIZE", "STATUS"]
    if detailed {
        header += ["STATE", "RPM", "LIFE", "ERRORS"]
        if warm { header.append("TEMP") }
        header.append("FIRMWARE")
    }
    header.append("MODEL")

    var rows: [[String]] = [header]
    for slot in slots {
        var row: [String] = [bayLabel(slot), slot.isEmpty ? "-" : human(slot.physicalBytes), slot.statusText]
        if detailed {
            let speed: String = slot.isSolidState ? "SSD" : (slot.rpm.map { String($0) } ?? "-")
            let life: String = slot.lifeRemaining.map { "\($0)%" } ?? "-"
            let errors: String = slot.errorCount.map { String($0) } ?? "-"
            let state: String = slot.diskStateText ?? "-"
            row += [state, speed, life, errors]
            if warm {
                let temperature: String = slot.temperature.map { "\($0) C" } ?? "-"
                row.append(temperature)
            }
            row.append(slot.firmwareRevision.isEmpty ? "-" : slot.firmwareRevision)
        }
        row.append(slot.isEmpty ? "-" : slot.model)
        rows.append(row)
    }
    return table(rows)
}

func volumesText(_ luns: [DroboLUN]) -> String {
    guard !luns.isEmpty else { return "No volumes reported." }
    return table([["UNIT", "SIZE", "ACCESS", "DISK", "ID", "MOUNTED", "NAME"]] + luns.map {
        let names = $0.isMounted ? $0.volumeNames : $0.knownNames
        return ["\($0.id)", human($0.bytes), $0.writable ? "read/write" : "read-only", $0.bsdName ?? "-",
                $0.uniqueID.map { "\($0)" } ?? "-", $0.isMounted ? "yes" : "no",
                names.isEmpty ? "-" : names.joined(separator: ", ")]
    })
}

// MARK: JSON output

func driveJSON(_ slot: DroboSlot) -> [String: Any] {
    var drive: [String: Any] = ["bay": bayLabel(slot), "empty": slot.isEmpty, "bytes": slot.physicalBytes,
                                "model": slot.model, "status": slot.statusText]
    if let temperature = slot.temperature { drive["temperatureC"] = temperature }
    if let errors = slot.errorCount { drive["errorCount"] = errors }
    if let life = slot.lifeRemaining { drive["lifeRemainingPercent"] = life }
    if let rpm = slot.rpm { drive["rpm"] = rpm }
    if slot.errorCount != nil { drive["solidState"] = slot.isSolidState }
    if let state = slot.diskStateText { drive["diskState"] = state }
    if let type = slot.diskTypeText { drive["diskType"] = type }
    if !slot.firmwareRevision.isEmpty { drive["firmware"] = slot.firmwareRevision }
    if !slot.serial.isEmpty { drive["serial"] = slot.serial }
    return drive
}

func volumeJSON(_ lun: DroboLUN) -> [String: Any] {
    ["unit": lun.id, "bytes": lun.bytes, "writable": lun.writable, "mounted": lun.isMounted,
     "names": lun.volumeNames, "known_names": lun.knownNames,
     "disk": lun.bsdName ?? NSNull(), "id": lun.uniqueID ?? NSNull()]
}

func deviceJSON(_ state: State) -> [String: Any] {
    let snapshot = state.snapshot
    var device: [String: Any] = [
        "connected": snapshot.driverPresent, "ready": snapshot.ready, "status": state.health.word,
        "name": state.name, "serial": snapshot.serial, "firmware": snapshot.firmware,
        "rebuilding": snapshot.isRebuilding, "blocksLeft": snapshot.relayoutCount, "alerts": state.alerts,
        "drives": state.filledBays, "bays": snapshot.slots.count,
    ]
    if let capacity = state.capacity {
        device["usedBytes"] = capacity.used
        device["freeBytes"] = capacity.total - capacity.used
        device["totalBytes"] = capacity.total
        device["percentUsed"] = state.percent ?? 0
    }
    if let dual = snapshot.dualDiskRedundancy { device["dualDiskRedundancy"] = dual }
    if let minutes = snapshot.spinDownMinutes { device["spinDownMinutes"] = minutes }
    if let temperature = snapshot.systemTemperature { device["temperatureC"] = temperature }
    if let uptime = snapshot.uptime { device["uptimeSeconds"] = uptime }
    if !snapshot.fanLevels.isEmpty { device["fanLevels"] = snapshot.fanLevels }
    return device
}

func printJSON(_ value: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    print(String(decoding: data, as: UTF8.self))
}

// MARK: Metrics

/// Prometheus exposition format. Always exits 0: `drobo_up` and `drobo_ready` carry the state.
func metricsText(_ state: State) -> String {
    let snapshot = state.snapshot
    var lines: [String] = []
    func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
    }
    func metric(_ name: String, _ help: String, _ type: String = "gauge", _ samples: [(labels: [(String, String)], value: String)]) {
        guard !samples.isEmpty else { return }
        lines.append("# HELP \(name) \(help)")
        lines.append("# TYPE \(name) \(type)")
        for sample in samples {
            let labels = sample.labels.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: ",")
            lines.append(labels.isEmpty ? "\(name) \(sample.value)" : "\(name){\(labels)} \(sample.value)")
        }
    }
    func one(_ value: String) -> [(labels: [(String, String)], value: String)] { [([], value)] }

    metric("drobo_up", "1 if the driver is attached to a Drobo.", "gauge", one(snapshot.driverPresent ? "1" : "0"))
    metric("drobo_ready", "1 if the Drobo has finished starting.", "gauge", one(snapshot.ready ? "1" : "0"))
    guard snapshot.ready else { return lines.joined(separator: "\n") }

    metric("drobo_health", "0 healthy, 1 warning or rebuilding, 2 needs attention.", "gauge", one("\(state.health.code)"))
    metric("drobo_status_flags", "Raw status flags from the Drobo.", "gauge", one("\(snapshot.statusFlags ?? 0)"))
    metric("drobo_rebuilding", "1 while data protection is in progress.", "gauge", one(snapshot.isRebuilding ? "1" : "0"))
    metric("drobo_rebuild_blocks_left", "Blocks left to rebuild.", "gauge", one("\(snapshot.relayoutCount)"))
    if let capacity = state.capacity {
        metric("drobo_capacity_bytes", "Protected capacity by kind.", "gauge", [
            ([("kind", "used")], "\(capacity.used)"),
            ([("kind", "free")], "\(capacity.total - capacity.used)"),
            ([("kind", "total")], "\(capacity.total)"),
        ])
    }
    if let temperature = snapshot.systemTemperature {
        metric("drobo_temperature_celsius", "Enclosure temperature (needs details turned on in the app).", "gauge", one("\(temperature)"))
    }
    if let uptime = snapshot.uptime {
        metric("drobo_uptime_seconds", "Time since the Drobo started (needs details turned on).", "gauge", one("\(uptime)"))
    }
    metric("drobo_fan_level", "Fan speed level as the Drobo reports it (needs details turned on).", "gauge",
           snapshot.fanLevels.enumerated().map { ([("fan", "\($0.offset + 1)")], "\($0.element)") })
    let filled = snapshot.slots.filter { !$0.isEmpty }
    metric("drobo_bays", "Number of drive bays.", "gauge", one("\(snapshot.slots.count)"))
    metric("drobo_drive_healthy", "1 if the drive in this bay reports healthy.", "gauge",
           filled.map { ([("bay", bayLabel($0)), ("model", $0.model), ("status", $0.statusText.lowercased())], $0.statusCode & 0x0F == 3 ? "1" : "0") })
    metric("drobo_drive_size_bytes", "Physical size of the drive in this bay.", "gauge",
           filled.map { ([("bay", bayLabel($0))], "\($0.physicalBytes)") })
    metric("drobo_drive_temperature_celsius", "Drive temperature (needs drive details turned on in the app).", "gauge",
           filled.compactMap { slot in slot.temperature.map { ([("bay", bayLabel(slot))], "\($0)") } })
    metric("drobo_drive_errors", "Drive error count as the Drobo reports it (needs drive details turned on).", "gauge",
           filled.compactMap { slot in slot.errorCount.map { ([("bay", bayLabel(slot))], "\($0)") } })
    metric("drobo_drive_life_remaining_percent", "Rated life left (needs drive details turned on).", "gauge",
           filled.compactMap { slot in slot.lifeRemaining.map { ([("bay", bayLabel(slot))], "\($0)") } })
    metric("drobo_volume_mounted", "1 if a volume on this unit is mounted.", "gauge",
           state.luns.map { ([("unit", "\($0.id)"), ("name", $0.volumeNames.joined(separator: ", "))], $0.isMounted ? "1" : "0") })
    metric("drobo_volume_writable", "1 if writing is allowed on this unit.", "gauge",
           state.luns.map { ([("unit", "\($0.id)")], $0.writable ? "1" : "0") })
    metric("drobo_driver_reads_total", "Read requests since the driver started.", "counter", one("\(snapshot.reads)"))
    metric("drobo_driver_writes_total", "Write requests since the driver started.", "counter", one("\(snapshot.writes)"))
    metric("drobo_driver_read_bytes_total", "Bytes read since the driver started.", "counter", one("\(snapshot.readBytes)"))
    metric("drobo_driver_written_bytes_total", "Bytes written since the driver started.", "counter", one("\(snapshot.writeBytes)"))
    metric("drobo_driver_io_errors_total", "I/O errors since the driver started.", "counter", one("\(snapshot.errors)"))
    return lines.joined(separator: "\n")
}

// MARK: get

let keys = """
status          healthy, rebuilding, warning, needs attention, starting, not connected
name  serial  firmware
used  free  total            bytes
used-human  free-human  total-human
percent                      whole number, capacity used
rebuilding                   yes or no
blocks-left                  rebuild blocks remaining
redundancy                   single or dual
spin-down                    minutes, 0 when off
drives  bays                 drives installed, bays in total
alerts                       one per line
temperature  uptime  fans    enclosure, when drive and system details are on in the app
drive.<bay>.status|size|size-human|model          bay is 1-8 or ssd
drive.<bay>.errors|life|rpm|firmware|serial|temperature   only when details are on in the app
volume.<name|unit>.mounted|size|size-human|access|disk|name
"""

func value(for key: String, in state: State) -> String? {
    let snapshot = state.snapshot
    let parts = key.split(separator: ".").map(String.init)
    if parts.count == 3, parts[0] == "drive", let slot = state.slot(parts[1]) {
        switch parts[2] {
        case "status": return slot.statusText.lowercased()
        case "size": return "\(slot.physicalBytes)"
        case "size-human": return slot.isEmpty ? "-" : human(slot.physicalBytes)
        case "model": return slot.model
        case "temperature": return slot.temperature.map { "\($0)" }
        case "errors": return slot.errorCount.map { "\($0)" }
        case "life": return slot.lifeRemaining.map { "\($0)" }
        case "rpm": return slot.isSolidState ? "0" : slot.rpm.map { "\($0)" }
        case "firmware": return slot.firmwareRevision.isEmpty ? nil : slot.firmwareRevision
        case "serial": return slot.serial.isEmpty ? nil : slot.serial
        default: return nil
        }
    }
    if parts.count >= 3, parts[0] == "volume" {
        // A volume name may itself contain dots, so the field is whatever follows the last one.
        guard let lun = state.lun(parts[1..<(parts.count - 1)].joined(separator: ".")) else { return nil }
        switch parts[parts.count - 1] {
        case "mounted": return lun.isMounted ? "yes" : "no"
        case "size": return "\(lun.bytes)"
        case "size-human": return human(lun.bytes)
        case "access": return lun.writable ? "read/write" : "read-only"
        case "disk": return lun.bsdName ?? ""
        case "name": return lun.volumeNames.joined(separator: ", ")
        default: return nil
        }
    }
    switch key {
    case "status": return state.health.word
    case "name": return state.name
    case "serial": return snapshot.serial
    case "firmware": return snapshot.firmware
    case "used": return state.capacity.map { "\($0.used)" }
    case "free": return state.capacity.map { "\($0.total - $0.used)" }
    case "total": return state.capacity.map { "\($0.total)" }
    case "used-human": return state.capacity.map { human($0.used) }
    case "free-human": return state.capacity.map { human($0.total - $0.used) }
    case "total-human": return state.capacity.map { human($0.total) }
    case "percent": return state.percent.map { "\($0)" }
    case "rebuilding": return snapshot.isRebuilding ? "yes" : "no"
    case "blocks-left": return "\(snapshot.relayoutCount)"
    case "redundancy": return snapshot.dualDiskRedundancy.map { $0 ? "dual" : "single" }
    case "spin-down": return snapshot.spinDownMinutes.map { "\($0)" }
    case "drives": return "\(state.filledBays)"
    case "bays": return "\(snapshot.slots.count)"
    case "alerts": return state.alerts.joined(separator: "\n")
    case "temperature": return snapshot.systemTemperature.map { "\($0)" }
    case "uptime": return snapshot.uptime.map { "\($0)" }
    case "fans": return snapshot.fanLevels.isEmpty ? nil : snapshot.fanLevels.map { "\($0)" }.joined(separator: " ")
    default: return nil
    }
}

// MARK: Main

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var json = false
var short = false
var watch: Double?
var demo: String?
var positional: [String] = []
var summaryOnly = false
var problemsOnly = false
var baySlot: Int?
var sizeText: String?
var typedSerial: String?
var yesReally = false
var volumeSizeText: String?
var volumeName: String?
var fileSystemText = "apfs"

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--json": json = true
    case "--short": short = true
    case "--watch":
        if let next = arguments.first, let seconds = Double(next) {
            watch = max(0.5, seconds)
            arguments.removeFirst()
        } else {
            watch = 2
        }
    case "--summary": summaryOnly = true
    case "--problems": problemsOnly = true
    case "--bay":
        guard !arguments.isEmpty else { fail("--bay needs a bay: 1-8 or ssd") }
        let name = arguments.removeFirst().lowercased()
        if name == "ssd" {
            baySlot = 8
        } else if let number = Int(name), (1...8).contains(number) {
            baySlot = number - 1
        } else {
            fail("--bay needs a bay: 1-8 or ssd")
        }
    case "--size":
        guard !arguments.isEmpty else { fail("--size needs a size, e.g. 16TB, 500GB or max") }
        sizeText = arguments.removeFirst()
    case "--serial":
        guard !arguments.isEmpty else { fail("--serial needs the Drobo's serial number") }
        typedSerial = arguments.removeFirst()
    case "--yes-really": yesReally = true
    case "--volume-size":
        guard !arguments.isEmpty else { fail("--volume-size needs a size such as 16TB") }
        volumeSizeText = arguments.removeFirst()
    case "--name":
        guard !arguments.isEmpty else { fail("--name needs a volume name") }
        volumeName = arguments.removeFirst()
    case "--fs":
        guard !arguments.isEmpty else { fail("--fs needs apfs or hfs") }
        fileSystemText = arguments.removeFirst().lowercased()
    case "--demo":
        guard !arguments.isEmpty else { fail("--demo needs healthy or rebuilding") }
        demo = arguments.removeFirst()
    case "-h", "--help", "help":
        print(usage)
        exit(0)
    default:
        if argument.hasPrefix("-") { fail("unknown option \(argument)\n\n\(usage)") }
        positional.append(argument)
    }
}

let command = positional.first ?? "status"

/// Runs one command that changes the Drobo: checks, shows what it would do, confirms, sends,
/// waits for the Drobo's answer. Returns the exit status.
func runVolume(_ action: DroboVolumeAction, state: State) -> Int32 {
    func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    guard demo == nil else {
        say("not available with --demo")
        return 1
    }
    let snapshot = state.snapshot
    if let blocker = DroboMonitor.volumeBlocker(action, snapshot: snapshot, volumes: state.volumes) {
        say(blocker)
        return 1
    }
    print("\(state.name), serial \(snapshot.serial.trimmingCharacters(in: .whitespaces))")
    print(action.summary(snapshot, luns: state.luns))
    guard yesReally else {
        print("Nothing was sent. Add --yes-really to do it.")
        return 2
    }
    var serial = typedSerial
    if serial == nil, isatty(STDIN_FILENO) != 0 {
        print("Type the Drobo's serial number to confirm: ", terminator: "")
        fflush(stdout)
        serial = readLine()
    }
    guard let serial, DroboMonitor.serialMatches(serial, snapshot: snapshot) else {
        say("The serial number does not match this Drobo. Nothing was sent.")
        return 1
    }
    if let failure = DroboMonitor.sendVolume(action, snapshot: snapshot) {
        say(failure)
        return 1
    }
    // The driver has the command; the Drobo gets two minutes to answer it.
    let deadline = Date().addingTimeInterval(150)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.5)
        let now = DroboMonitor.snapshot()
        guard now.driverPresent else {
            if action.isReset {
                print("The Drobo has disconnected, which is what a reset does: it is erasing its drives and restarting.")
                return 0
            }
            say("The Drobo disconnected before answering.")
            return 1
        }
        if let outcome = DroboMonitor.volumeOutcome(action, snapshot: now) {
            if outcome.ok { print(outcome.text) } else { say(outcome.text) }
            return outcome.ok ? 0 : 1
        }
    }
    say("No answer was reported. Check `drobo volumes` before trying again.")
    return 1
}

/// Prints one command's output and returns the exit status.
func run() -> Int32 {
    let state = State.load(demo: demo)
    let code = state.health.code
    switch command {
    case "reset":
        guard let text = volumeSizeText else { return runVolume(.reset, state: state) }
        guard let bytes = DroboVolumeAction.parseSize(text, max: 0), bytes % (1 << 40) == 0 else {
            fail("--volume-size needs a whole number of TB: 1, 2, 4, 8, 16, 32, 64 or 128")
        }
        return runVolume(.resetWithVolumeSize(tib: Int(bytes >> 40)), state: state)
    case "volume" where positional.count > 1 && positional[1] == "create":
        let largest = state.snapshot.maxVolumeBytes
        guard let bytes = DroboVolumeAction.parseSize(sizeText ?? "max", max: largest) else {
            fail(sizeText == nil ? "the Drobo has not reported its largest volume size yet; give --size"
                                 : "--size needs a size such as 16TB, 500GB or max")
        }
        return runVolume(.create(bytes: bytes), state: state)
    case "speedtest":
        guard demo == nil else { fail("not available with --demo") }
        guard positional.count > 1 else { fail("speedtest needs a volume name or unit number") }
        guard let lun = state.lun(positional[1]), let volume = state.volumes.first(where: { $0.lun == lun.id }) else {
            FileHandle.standardError.write(Data("no mounted volume by that name or unit\n".utf8))
            return 1
        }
        guard lun.writable else {
            FileHandle.standardError.write(Data("\(volume.name) is read-only. Turn on Allow writes for it in the app first.\n".utf8))
            return 1
        }
        guard let bytes = DroboVolumeAction.parseSize(sizeText ?? "1GB", max: 0), bytes >= 64 << 20 else {
            fail("--size needs a size of at least 64 MB, such as 1GB or 5GB")
        }
        let showProgress = !json && isatty(STDOUT_FILENO) != 0
        var lastPhase: DroboMonitor.SpeedTestPhase?
        let outcome = DroboMonitor.speedTest(on: volume.id, megabytes: Int(bytes >> 20)) { phase, fraction, speed in
            guard showProgress else { return }
            if let last = lastPhase, last != phase { print("") }
            lastPhase = phase
            print(String(format: "\r%@ %3.0f%%  %.0f MB/s   ", phase == .writing ? "write" : "read ", fraction * 100, speed), terminator: "")
            fflush(stdout)
        }
        if showProgress { print("") }
        switch outcome {
        case .success(let result):
            if json {
                printJSON(["volume": volume.name, "unit": lun.id, "bytes": result.bytes,
                           "write_mb_per_s": NSDecimalNumber(string: String(format: "%.1f", result.writeSpeed)),
                           "read_mb_per_s": NSDecimalNumber(string: String(format: "%.1f", result.readSpeed))])
            } else {
                print(String(format: "%@: write %.0f MB/s, read %.0f MB/s (%@ test file, file cache bypassed)",
                             volume.name, result.writeSpeed, result.readSpeed, human(UInt64(result.bytes))))
            }
            return 0
        case .failure(let failure):
            FileHandle.standardError.write(Data((failure.text + "\n").utf8))
            return 1
        }
    case "volume" where positional.count > 1 && positional[1] == "format":
        guard demo == nil else { fail("not available with --demo") }
        guard positional.count > 2, let unit = Int(positional[2]), (0..<32).contains(unit) else {
            fail("volume format needs a unit number (see `drobo volumes`)")
        }
        guard let name = volumeName else { fail("volume format needs --name <name>") }
        guard let fileSystem: DroboMonitor.FileSystem = ["apfs": .apfs, "hfs": .hfs][fileSystemText] else {
            fail("--fs needs apfs or hfs")
        }
        print("Format unit \(unit) as \(fileSystem.label), named \(name). Only a blank unit is ever formatted.")
        guard yesReally else {
            print("Nothing was done. Add --yes-really to do it.")
            return 2
        }
        let result = DroboMonitor.formatBlankUnit(unit, name: name, fileSystem: fileSystem) { print($0) }
        if result.ok { print(result.text) } else { FileHandle.standardError.write(Data((result.text + "\n").utf8)) }
        return result.ok ? 0 : 1
    case "volume" where positional.count > 1 && positional[1] == "delete":
        guard positional.count > 2, let unit = Int(positional[2]), (0..<256).contains(unit) else {
            fail("volume delete needs a unit number (see `drobo volumes`)")
        }
        return runVolume(.delete(unit: unit), state: state)
    case "status":
        if json { printJSON(deviceJSON(state)) } else { print(statusLine(state, short: short)) }
    case "device":
        if json { printJSON(deviceJSON(state)) } else { print(deviceText(state)) }
    case "drives":
        if json { printJSON(state.snapshot.slots.map(driveJSON)) } else { print(drivesText(state.snapshot.slots)) }
    case "drive":
        guard positional.count > 1 else { fail("drive needs a bay: 1-8 or ssd") }
        guard let slot = state.slot(positional[1]) else {
            FileHandle.standardError.write(Data("no such bay\n".utf8))
            return code == 0 ? 1 : code
        }
        if json { printJSON(driveJSON(slot)) } else { print(drivesText([slot])) }
    case "volumes":
        if json { printJSON(state.luns.map(volumeJSON)) } else { print(volumesText(state.luns)) }
    case "volume":
        guard positional.count > 1 else { fail("volume needs a name or unit number") }
        guard let lun = state.lun(positional[1]) else {
            FileHandle.standardError.write(Data("no such volume\n".utf8))
            return code == 0 ? 1 : code
        }
        if json { printJSON(volumeJSON(lun)) } else { print(volumesText([lun])) }
    case "all":
        if json {
            printJSON(["device": deviceJSON(state), "drives": state.snapshot.slots.map(driveJSON),
                       "volumes": state.luns.map(volumeJSON)])
        } else {
            print(deviceText(state))
            if state.snapshot.ready {
                print("\n" + drivesText(state.snapshot.slots) + "\n\n" + volumesText(state.luns))
            }
        }
    case "get":
        guard positional.count > 1 else { fail("get needs a key; see `drobo keys`") }
        guard let result = value(for: positional[1], in: state) else {
            FileHandle.standardError.write(Data("no value for \(positional[1])\n".utf8))
            return code == 0 ? 1 : code
        }
        print(result)
    case "keys":
        print(keys)
        return 0
    case "metrics":
        print(metricsText(state))
        return 0
    case "log":
        // Prints what the driver already holds. Asking the Drobo for it is done in the app.
        var data: Data?
        if demo != nil {
            data = Data(DroboLog.demo.utf8)
        } else if state.snapshot.eventLogState == 2 {
            data = DroboLog.fetch(length: state.snapshot.eventLogLength)
        }
        guard let data else {
            FileHandle.standardError.write(Data("No log read yet. Open the app's Events tab and press Read from Drobo.\n".utf8))
            return 1
        }
        var entries = DroboLog.parse(data)
        if summaryOnly {
            let summary = DroboLogSummary.make(entries)
            if json {
                let stamp = ISO8601DateFormatter()
                var result: [String: Any] = [
                    "events": summary.count,
                    "powerOns": summary.powerOns,
                    "unexpectedPowerLosses": summary.powerLosses.map { stamp.string(from: $0) },
                    "internalErrors": summary.internalErrors.map { stamp.string(from: $0) },
                    "overheating": summary.overheating.map { $0.text },
                    "rebuilds": summary.rebuilds.map { rebuild -> [String: Any] in
                        var row: [String: Any] = ["start": stamp.string(from: rebuild.start)]
                        if let end = rebuild.end {
                            row["end"] = stamp.string(from: end)
                            row["seconds"] = Int(end.timeIntervalSince(rebuild.start))
                        }
                        return row
                    },
                    "healthChecks": summary.healthChecks.map { ["date": stamp.string(from: $0.date), "mebibytesPerSecond": $0.speed] as [String: Any] },
                    "usedPercent": summary.capacity.map { ["date": stamp.string(from: $0.date), "percent": $0.usedPercent] as [String: Any] },
                    "bays": summary.bays.map { bay -> [String: Any] in
                        var row: [String: Any] = ["bay": bay.name, "drives": bay.drives.count, "problems": bay.problems.map { $0.text }]
                        if let drive = bay.drives.last {
                            row["capacity"] = drive.capacity
                            row["since"] = stamp.string(from: drive.firstSeen)
                        }
                        return row
                    },
                ]
                if let first = summary.first { result["from"] = stamp.string(from: first) }
                if let last = summary.last { result["to"] = stamp.string(from: last) }
                printJSON(result)
            } else {
                print(summary.lines().joined(separator: "\n"))
            }
            return 0
        }
        if let baySlot { entries = entries.filter { $0.slot == baySlot } }
        if problemsOnly { entries = entries.filter { $0.severity > 0 || !$0.isKnown } }
        if json {
            var rows: [[String: Any]] = []
            for entry in entries {
                var row: [String: Any] = ["time": entry.stamp, "code": entry.code, "severity": entry.severity, "text": entry.text]
                var details: [String: String] = [:]
                for parameter in entry.parameters { details[parameter.key] = parameter.value }
                row["parameters"] = details
                rows.append(row)
            }
            printJSON(rows)
        } else {
            for entry in entries {
                let mark = entry.severity >= 2 ? "!" : (entry.severity == 1 ? "*" : " ")
                print("\(entry.stamp)  \(mark) \(entry.text)")
            }
        }
        return 0
    case "history":
        // Recorded by the app (or its menu bar item) while it runs; this only reads the file.
        let file: BayHistoryFile
        if let demo { file = .demo(rebuilding: demo == "rebuilding") } else { file = BayHistory.load() }
        let report = BayHistory.analyze(file)
        if json { printJSON(historyJSON(report)) } else { print(historyText(report)) }
        return report.headline.isEmpty ? 0 : 1
    case "diagnostics":
        // The command usually runs through a link in /usr/local/bin; resolve it to find the app.
        let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let version = app.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        printJSON(DroboMonitor.diagnostics(appVersion: version, commit: ""))
        return 0
    default:
        fail("unknown command \(command)\n\n\(usage)")
    }
    return code
}

// A command that changes the Drobo runs once, whatever --watch says.
let changesDrobo = command == "reset" || command == "speedtest" ||
    (command == "volume" && positional.count > 1 && ["create", "delete", "format"].contains(positional[1]))
if let watch, !changesDrobo {
    while true {
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        _ = run()
        fflush(stdout)
        Thread.sleep(forTimeInterval: watch)
    }
} else {
    exit(run())
}
