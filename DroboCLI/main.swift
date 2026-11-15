import Foundation

/// `drobo`: read-only status from the command line, for shell prompts, tmux/vim status lines,
/// scripts and dashboards. It reads what the driver publishes (the same source as the app) and
/// never sends anything to the Drobo.
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
  diagnostics            raw driver state and management pages as JSON, serial and name redacted
  metrics                Prometheus text format, for node_exporter's textfile collector, Telegraf, etc.

options
  --json                 machine-readable output (status, device, drives, volumes, all)
  --short                compact status, e.g. "Drobo ok 34%"
  --watch [seconds]      redraw until interrupted (default 2)
  --demo <healthy|rebuilding>   made-up data, no driver needed

exit status: 0 healthy, 1 warning or rebuilding, 2 needs attention, 3 not connected
"""

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
        if let match = luns.first(where: { $0.volumeNames.contains { $0.caseInsensitiveCompare(text) == .orderedSame } }) {
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
    // Temperature and errors appear only when the optional drive page is on (see the app).
    let detailed = slots.contains { $0.errorCount != nil }
    let warm = slots.contains { $0.temperature != nil }
    func speed(_ slot: DroboSlot) -> String { slot.isSolidState ? "SSD" : (slot.rpm.map { "\($0)" } ?? "-") }
    let header = ["BAY", "SIZE", "STATUS"] + (detailed ? ["RPM", "LIFE", "ERRORS"] + (warm ? ["TEMP"] : []) + ["FIRMWARE"] : []) + ["MODEL"]
    return table([header] + slots.map { slot in
        [bayLabel(slot), slot.isEmpty ? "-" : human(slot.physicalBytes), slot.statusText]
            + (detailed ? [speed(slot), slot.lifeRemaining.map { "\($0)%" } ?? "-", slot.errorCount.map { "\($0)" } ?? "-"]
                + (warm ? [slot.temperature.map { "\($0) C" } ?? "-"] : [])
                + [slot.firmwareRevision.isEmpty ? "-" : slot.firmwareRevision] : [])
            + [slot.isEmpty ? "-" : slot.model]
    })
}

func volumesText(_ luns: [DroboLUN]) -> String {
    guard !luns.isEmpty else { return "No volumes reported." }
    return table([["UNIT", "SIZE", "ACCESS", "DISK", "MOUNTED"]] + luns.map {
        ["\($0.id)", human($0.bytes), $0.writable ? "read/write" : "read-only", $0.bsdName ?? "-",
         $0.isMounted ? $0.volumeNames.joined(separator: ", ") : "-"]
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
    if !slot.firmwareRevision.isEmpty { drive["firmware"] = slot.firmwareRevision }
    if !slot.serial.isEmpty { drive["serial"] = slot.serial }
    return drive
}

func volumeJSON(_ lun: DroboLUN) -> [String: Any] {
    ["unit": lun.id, "bytes": lun.bytes, "writable": lun.writable, "mounted": lun.isMounted,
     "names": lun.volumeNames, "disk": lun.bsdName ?? NSNull()]
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

/// Prints one command's output and returns the exit status.
func run() -> Int32 {
    let state = State.load(demo: demo)
    let code = state.health.code
    switch command {
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

if let watch {
    while true {
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        _ = run()
        fflush(stdout)
        Thread.sleep(forTimeInterval: watch)
    }
} else {
    exit(run())
}
