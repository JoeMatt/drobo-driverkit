import CryptoKit
import DiskArbitration
import Foundation
import IOKit

/// Reads what the driver publishes in the IORegistry and decodes the Drobo's management pages.
///
/// The driver polls the pages (MODE SENSE 10, page 0x3A) and publishes the raw bytes under
/// `DroboHealth`; its own counters are under `DroboStatus`. Page layouts follow the open-source
/// drobo-utils project. Everything on the wire is big-endian.

struct DroboSlot: Identifiable {
    let id: Int
    let physicalBytes: UInt64
    let statusCode: UInt8
    let model: String
    /// How much of the drive the Drobo is using for its disk pack, as the slot page reports it.
    var managedBytes: UInt64 = 0
    /// Drive interface from the slot page's identity field, e.g. "SATA".
    var interface = ""

    // From the optional second slot page (sub-page 0x35, protocol notes 11.9). All nil or empty
    // unless the app has turned that page on and the Drobo answers it.
    /// Degrees Celsius (Drobo Dashboard prints this field followed by "C").
    var temperature: Int?
    var errorCount: Int?
    var firmwareRevision = ""
    var serial = ""
    /// Percent of rated life left. Observed on the 8D: 100 for hard disks, 99 for an SSD.
    var lifeRemaining: Int?
    /// Raw rotation field. Observed on the 8D: 1 for an SSD, otherwise rpm / 200
    /// (27 for 5400 rpm drives, 36 for 7200 rpm drives).
    var rotationalSpeed: Int?
    /// 0 for hard disks and 2 for the SSD on the 8D.
    var diskType: Int?
    /// The Drobo's own verdict on the drive. Drobo Dashboard reads only the low four bits
    /// (protocol notes 11.16); the 8D also sets 0x10 or 0x20, which Dashboard ignores.
    var diskState: UInt32?

    /// 0 good, 1 healed, 2 warning, 3 failed.
    var diskStateCode: Int? { diskState.map { Int($0 & 0x0F) } }
    var diskStateText: String? {
        guard let code = diskStateCode else { return nil }
        switch code {
        case 0: return "Good"
        case 1: return "Healed"
        case 2: return "Warning"
        case 3: return "Failed"
        default: return "Unknown (\(code))"
        }
    }
    var diskTypeText: String? {
        guard let type = diskType else { return nil }
        switch type {
        case 0: return "SATA hard disk"
        case 1: return "SAS hard disk"
        case 2: return "SATA SSD"
        case 3: return "SAS SSD"
        case 4: return "mSATA SSD"
        default: return nil
        }
    }

    var isSolidState: Bool { rotationalSpeed == 1 || (diskType.map { $0 >= 2 && $0 <= 4 } ?? false) }
    var rpm: Int? { rotationalSpeed.flatMap { $0 > 1 ? $0 * 200 : nil } }

    var isEmpty: Bool { statusCode == 0x80 }

    /// What the bay light is doing, as documented by drobo-utils.
    var statusText: String {
        if isEmpty { return "Empty" }
        switch statusCode & 0x0F {
        case 0: return "Off"
        case 1: return "Failed"
        case 2: return "Replace soon"
        case 3: return "Healthy"
        case 4: return "Rebuilding"
        case 5: return "Warning"
        case 6: return "Failed, replace"
        case 7: return "Warning (yellow and red)"
        case 8: return "Warning (flashing yellow)"
        default: return "Unknown (\(statusCode))"
        }
    }
}

struct DroboVolume: Identifiable {
    let id: URL
    let name: String
    let totalBytes: Int64
    /// The Drobo logical unit this volume lives on.
    let lun: Int
    /// Free space as the file system reports it.
    var availableBytes: Int64 = 0
}

/// One logical unit as the Drobo presents it, with the mounted volume on it if there is one.
struct DroboLUN: Identifiable {
    let id: Int
    let bytes: UInt64
    /// Names of the mounted volumes on this unit (empty when nothing is mounted).
    let volumeNames: [String]
    /// BSD name of the unit's whole disk, e.g. "disk24"; nil if macOS has no disk for it.
    let bsdName: String?
    let writable: Bool

    var isMounted: Bool { !volumeNames.isEmpty }
}

/// Commands the driver accepts from the app (must match the driver's enum).
enum DroboCommand: UInt32 {
    case setWritable = 1
    case blink = 2
    case standby = 3
    case rename = 4
    case setOptions = 5
    case setExtended = 6
    case restart = 7
    case setDim = 8
    case getDim = 9
    case readLog = 10
}

/// The driver's own timing for one size class of block request.
struct DroboLatency: Identifiable {
    let id: String              // "4 KB", "64 KB", ...
    let count: UInt64
    let averageMicroseconds: UInt64
    let maxMicroseconds: UInt64
}

struct DroboSnapshot {
    var driverPresent = false
    var stage = ""
    var ready = false
    var serial = ""
    var interfaceVersion = 0
    var lunsPresent = 0
    var reads: UInt64 = 0
    var readBytes: UInt64 = 0
    var errors: UInt64 = 0
    var rejectedWrites: UInt64 = 0
    var inflight = 0
    var writes: UInt64 = 0
    var writeBytes: UInt64 = 0
    var writableMask: UInt32 = 0
    var lunBlocks: [UInt64] = []
    var dualDiskRedundancy: Bool?
    var optionFlags: UInt64 = 0
    var commands: UInt64 = 0
    var lastCommandResult = 0
    var flushForwarding = false
    var flushes: UInt64 = 0
    var spinDownMinutes: Int?

    var healthAvailable = false
    var healthCycles: UInt64 = 0
    var name = ""
    var firmware = ""
    var firmwareBuild = ""
    var firmwarePlatform = ""
    /// Capacity alert thresholds in percent used (options page 0x30).
    var yellowThreshold: Int?
    var redThreshold: Int?
    var latency: [DroboLatency] = []
    /// The driver is polling the optional pages / gave the per-drive page up after the Drobo
    /// refused it.
    var extendedEnabled = false
    var extendedFailed = false
    /// 2 when the running driver frames blink, standby and restart the way Drobo's own software
    /// does (driver 0.27.0 and later). Older drivers sent a malformed command that hung the 8D.
    var commandFormat = 0
    var systemOperationsSafe: Bool { commandFormat >= 2 }
    var dimmingAvailable: Bool { commandFormat >= 3 }
    /// The driver can ask the Drobo for its own event log (driver 0.29.0).
    var eventLogAvailable: Bool { commandFormat >= 4 && eventLogState != 4 }
    /// 0 never read, 1 reading, 2 read, 3 the Drobo did not return it, 4 the driver has no buffer for it.
    var eventLogState = 0
    var eventLogLength = 0
    /// LED dim level, 0 (brightest) to 9, once it has been read from the Drobo.
    var dimLevel: Int?

    // From the optional system pages (sub-pages 0x33, 0x37, 0x36, 0x34; protocol notes 11.11).
    // nil or empty unless those pages are on and the Drobo answers them.
    /// Enclosure temperature. Assumed to be degrees Celsius like the per-drive value.
    var systemTemperature: Int?
    /// Assumed to be seconds since the Drobo started; to be confirmed on hardware.
    var uptime: UInt32?
    /// Speed level per fan as the Drobo reports it (not confirmed to be RPM). Zero entries are dropped.
    var fanLevels: [UInt32] = []
    /// Raw health words whose encodings are not known yet; kept for diagnostics, not shown.
    var fanHealth: Int?
    var powerHealth: [Int] = []
    /// The Drobo's own performance counters (IOPS, read and write throughput), units unconfirmed.
    var deviceIOPS: UInt32?
    var deviceReadThroughput: UInt32?
    var deviceWriteThroughput: UInt32?
    var statusFlags: UInt32?
    var relayoutCount: UInt32 = 0
    var freeBytes: UInt64?
    var usedBytes: UInt64?
    var totalBytes: UInt64?
    var unprotectedBytes: UInt64?
    var slots: [DroboSlot] = []

    /// Status flag bits and what they mean (drobo-utils), in display order.
    static let statusTable: [(UInt32, String)] = [
        (0x0002, "Red alert: capacity critically low"),
        (0x0004, "Yellow alert: capacity low"),
        (0x0008, "No disks"),
        (0x0010, "Bad disk"),
        (0x0020, "Too many missing disks"),
        (0x0040, "No redundancy: a second failure would lose data"),
        (0x0080, "No hot spare"),
        (0x0100, "No space left"),
        (0x0200, "Data protection in progress (rebuilding)"),
        (0x0400, "Format in progress"),
        (0x0800, "Mismatched disks"),
        (0x1000, "Unknown firmware version"),
        (0x2000, "New firmware installed"),
        (0x4000, "New volume available after restart"),
        (0x8000, "Status bit 0x8000 (meaning not documented)"),
        (0x1_0000, "Status bit 0x10000 (meaning not documented)"),
        (0x1000_0000, "Unknown error"),
    ]

    var statusLines: [String] {
        guard let flags = statusFlags else { return [] }
        let table = Self.statusTable
        let lines = table.filter { flags & $0.0 != 0 }.map { $0.1 }
        return lines.isEmpty ? ["Healthy"] : lines
    }

    var isRebuilding: Bool { (statusFlags ?? 0) & 0x0200 != 0 || relayoutCount > 0 }
}

enum DroboMonitor {
    static func snapshot() -> DroboSnapshot {
        var snapshot = DroboSnapshot()
        guard let properties = driverProperties() else { return snapshot }
        snapshot.driverPresent = true

        if let status = properties["DroboStatus"] as? [String: Any] {
            snapshot.stage = status["Stage"] as? String ?? ""
            snapshot.ready = status["Ready"] as? Bool ?? false
            snapshot.serial = status["Serial"] as? String ?? ""
            snapshot.interfaceVersion = number(status["InterfaceVersion"])
            snapshot.lunsPresent = number(status["LUNsPresent"])
            snapshot.reads = UInt64(number(status["Reads"]))
            snapshot.readBytes = (status["ReadBytes"] as? NSNumber)?.uint64Value ?? 0
            snapshot.errors = UInt64(number(status["Errors"]))
            snapshot.rejectedWrites = UInt64(number(status["RejectedWrites"]))
            snapshot.inflight = number(status["Inflight"])
            snapshot.writes = UInt64(number(status["Writes"]))
            snapshot.writeBytes = (status["WriteBytes"] as? NSNumber)?.uint64Value ?? 0
            snapshot.writableMask = (status["WritableMask"] as? NSNumber)?.uint32Value ?? 0
            snapshot.commands = UInt64(number(status["Commands"]))
            snapshot.lastCommandResult = number(status["LastCommandSRB"])
            snapshot.flushForwarding = status["FlushForwarding"] as? Bool ?? false
            snapshot.flushes = UInt64(number(status["Flushes"]))
            snapshot.commandFormat = number(status["CommandFormat"])
            snapshot.eventLogState = Int(number(status["EventLogState"]))
            snapshot.eventLogLength = Int(number(status["EventLogLength"]))
            snapshot.dimLevel = (status["DimLevel"] as? NSNumber)?.intValue
            snapshot.extendedEnabled = status["ExtendedSlots"] as? Bool ?? false
            snapshot.extendedFailed = status["ExtendedSlotsFailed"] as? Bool ?? false
            snapshot.latency = [("4 KB", "4K"), ("64 KB", "64K"), ("256 KB", "256K"), ("512 KB", "512K")].map { label, key in
                DroboLatency(id: label,
                             count: UInt64(number(status["Latency\(key)Count"])),
                             averageMicroseconds: UInt64(number(status["Latency\(key)AvgUS"])),
                             maxMicroseconds: UInt64(number(status["Latency\(key)MaxUS"])))
            }
            if let data = status["LUNBlocks"] as? Data {
                snapshot.lunBlocks = data.withUnsafeBytes { raw in
                    (0..<(data.count / 8)).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self) }
                }
            }
        }

        guard let health = properties["DroboHealth"] as? [String: Any] else { return snapshot }
        snapshot.healthAvailable = health["Available"] as? Bool ?? false
        snapshot.healthCycles = UInt64(number(health["Cycles"]))

        // Every page starts with a 4-byte header: flags, sub-page code, big-endian length.
        if let page = payload(health["Status"]), page.count >= 8 {
            snapshot.statusFlags = be32(page, 0)
            snapshot.relayoutCount = be32(page, 4)
        }
        if let page = payload(health["Capacity"]), page.count >= 32 {
            snapshot.freeBytes = be64(page, 0)
            snapshot.usedBytes = be64(page, 8)
            snapshot.totalBytes = be64(page, 16)
            snapshot.unprotectedBytes = be64(page, 24)
        }
        if let page = payload(health["Settings"]), page.count >= 38 {
            snapshot.name = string(page, 6, 32)
        }
        if let page = payload(health["Firmware"]), page.count >= 70 {
            // 6 bytes of numeric fields, then build date[32], platform[16], version[16].
            // On the 8D the readable version ("4.2.3") is the third string.
            let version = string(page, 54, 16)
            snapshot.firmware = version.isEmpty ? "\(page[0]).\(page[1])" : version
            snapshot.firmwareBuild = string(page, 6, 32)
            snapshot.firmwarePlatform = string(page, 38, 16)
        }
        if let page = payload(health["Options"]), page.count >= 2,
           (1...100).contains(page[0]), (1...100).contains(page[1]) {
            // Observed on the 8D (protocol notes 11.6): yellow threshold, red threshold, percent.
            snapshot.yellowThreshold = Int(page[0])
            snapshot.redThreshold = Int(page[1])
        }
        if let page = payload(health["Options2"]), page.count >= 10 {
            // flags u64 (bit 0 dual disk redundancy, bit 1 spin-down enabled), minutes u16.
            let flags = be64(page, 0)
            snapshot.optionFlags = flags
            snapshot.dualDiskRedundancy = flags & 0x1 != 0
            snapshot.spinDownMinutes = flags & 0x2 != 0 ? Int(be16(page, 8)) : 0
        }
        if let page = payload(health["Slots"]), page.count >= 1 {
            // One count byte, then 72-byte records:
            // u16, slot id, physical u64, managed u64, status, identity[32], short identity[16], u32.
            let recordSize = 72
            var slots: [DroboSlot] = []
            var offset = 1
            while offset + recordSize <= page.count {
                let slotID = Int(page[offset + 2])
                // The 32-byte identity field is vendor[8], product[16], interface[8] ("SATA").
                let vendor = string(page, offset + 20, 8)
                let product = string(page, offset + 28, 16)
                slots.append(DroboSlot(id: slotID,
                                       physicalBytes: be64(page, offset + 3),
                                       statusCode: page[offset + 19],
                                       model: vendor.isEmpty ? product : vendor + " " + product,
                                       managedBytes: be64(page, offset + 11),
                                       interface: string(page, offset + 44, 8)))
                offset += recordSize
            }
            snapshot.slots = slots
        }
        if let page = payload(health["Slots2"]) { applySlots2(page, to: &snapshot) }
        applySystemPages(system: payload(health["System"]), fan: payload(health["Fan"]),
                         power: payload(health["Power"]), performance: payload(health["Performance"]), to: &snapshot)
        return snapshot
    }

    /// Decodes the optional system pages, each given without its 4-byte header (so every offset
    /// here is the page offset in protocol notes 11.11 minus 4).
    static func applySystemPages(system: [UInt8]?, fan: [UInt8]?, power: [UInt8]?, performance: [UInt8]?,
                                 to snapshot: inout DroboSnapshot) {
        if let page = system, page.count >= 12 {            // 0x33: uptime u32 @8, temperature u32 @0xC
            snapshot.uptime = be32(page, 4)
            let temperature = Int(be32(page, 8))
            snapshot.systemTemperature = (1...150).contains(temperature) ? temperature : nil
        }
        if let page = fan, page.count >= 38 {               // 0x37: health u16 @0x18, four u32 levels @0x1A
            snapshot.fanHealth = Int(be16(page, 20))
            snapshot.fanLevels = (0..<4).map { be32(page, 22 + 4 * $0) }.filter { $0 != 0 }
        }
        if let page = power, page.count >= 9 {              // 0x36: two health u16 @9 and @0xB
            snapshot.powerHealth = [Int(be16(page, 5)), Int(be16(page, 7))]
        }
        if let page = performance, page.count >= 16 {       // 0x34: IOPS, read, write u32 @8, @0xC, @0x10
            snapshot.deviceIOPS = be32(page, 4)
            snapshot.deviceReadThroughput = be32(page, 8)
            snapshot.deviceWriteThroughput = be32(page, 12)
        }
    }

    /// Fills in per-drive details from the optional second slot page (sub-page 0x35), given the
    /// page without its 4-byte header.
    // After the 4-byte page header: 4 bytes, slot count, record size, 2 bytes, then the
    // records (ESASlotInfo2::parse). Each is 108 bytes (ESASlotInfoStruct2::parse):
    // slot id, status, error count u16, disk state u32, disk type, temperature,
    // life remaining, rotational speed, model[44], firmware[12], serial[24], two u64.
    static func applySlots2(_ page: [UInt8], to snapshot: inout DroboSnapshot) {
        guard page.count >= 8 else { return }
        let count = Int(page[4])
        let stride = Int(page[5])
        var offset = 8
        var seen = 0
        while stride >= 108, seen < count, offset + 108 <= page.count {
            let slotID = Int(page[offset])
            if let index = snapshot.slots.firstIndex(where: { $0.id == slotID }), !snapshot.slots[index].isEmpty {
                snapshot.slots[index].errorCount = Int(be16(page, offset + 2))
                snapshot.slots[index].diskState = be32(page, offset + 4)
                snapshot.slots[index].diskType = Int(page[offset + 8])
                // The 8D reports 0 here for every drive, so 0 means "not reported".
                snapshot.slots[index].temperature = page[offset + 9] == 0 ? nil : Int(page[offset + 9])
                snapshot.slots[index].lifeRemaining = Int(page[offset + 10])
                snapshot.slots[index].rotationalSpeed = Int(page[offset + 11])
                snapshot.slots[index].firmwareRevision = string(page, offset + 0x38, 12)
                snapshot.slots[index].serial = string(page, offset + 0x44, 24)
            }
            offset += stride
            seen += 1
        }
    }

    /// Mounted volumes that live on one of the Drobo's logical units.
    static func volumes() -> [DroboVolume] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { return nil }
            let media = DADiskCopyIOMedia(disk)
            guard media != 0 else { return nil }
            defer { IOObjectRelease(media) }
            guard let lun = droboLUN(of: media) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return DroboVolume(id: url,
                               name: values?.volumeName ?? url.lastPathComponent,
                               totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
                               lun: lun,
                               availableBytes: Int64(values?.volumeAvailableCapacity ?? 0))
        }
    }

    /// Walks up the IORegistry from a disk to find which Drobo logical unit it belongs to.
    /// Works for APFS volumes too, whose synthesized disks sit several levels above the
    /// physical one. Returns nil for anything that is not on our driver.
    private static func droboLUN(of media: io_service_t) -> Int? {
        var lun: Int?
        var entry = media
        IOObjectRetain(entry)
        for _ in 0..<48 {
            if let number = IORegistryEntryCreateCFProperty(entry, "SCSI Logical Unit Number" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                lun = number.intValue
            }
            if let userClass = IORegistryEntryCreateCFProperty(entry, "IOUserClass" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, userClass == "DroboSCSIController" {
                IOObjectRelease(entry)
                return lun
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS, parent != 0 else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }

    /// BSD names of the whole disks macOS created for the Drobo's units, by LUN.
    private static func wholeDisks() -> [Int: String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }
        var disks: [Int: String] = [:]
        while case let media = IOIteratorNext(iterator), media != 0 {
            defer { IOObjectRelease(media) }
            guard let whole = IORegistryEntryCreateCFProperty(media, "Whole" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool, whole,
                  let bsd = IORegistryEntryCreateCFProperty(media, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let lun = droboLUN(of: media) else { continue }
            // A unit's physical disk is the lowest-numbered whole disk above it; APFS
            // containers on the same unit are synthesized later and get higher numbers.
            if let existing = disks[lun], diskNumber(existing) <= diskNumber(bsd) { continue }
            disks[lun] = bsd
        }
        return disks
    }

    private static func diskNumber(_ bsd: String) -> Int { Int(bsd.dropFirst(4)) ?? Int.max }

    /// How to run diskutil as root for an account that may not do it itself: a verb and
    /// the BSD names to apply it to, returning nil on success. The app installs
    /// `PrivilegedHelper.diskutil` here; the command line tool and the helper leave it nil.
    static var elevatedDiskutil: ((String, [String]) -> String?)?

    /// Whether a BSD name ("disk5", "disk5s1") is a disk or volume on one of the Drobo's
    /// units. The privileged helper refuses anything else.
    static func isDroboDisk(bsdName: String) -> Bool {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return false }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return false }
        defer { IOObjectRelease(media) }
        return droboLUN(of: media) != nil
    }

    /// Runs one diskutil verb on one disk as the current user. Returns nil on success.
    static func diskutil(_ verb: String, _ bsdName: String) -> String? {
        guard let result = runTool("/usr/sbin/diskutil", [verb, bsdName]) else { return "Could not run diskutil." }
        return result.status == 0 ? nil : result.output
    }

    /// Mounts or unmounts every volume on one of the Drobo's disks. Returns nil on success.
    /// A standard (non-admin) account is not allowed to do this for a disk it did not mount
    /// itself, so when it fails for such an account it is retried with an administrator's
    /// authorisation.
    static func setMounted(_ mounted: Bool, bsdName: String) -> String? {
        let verb = mounted ? "mountDisk" : "unmountDisk"
        guard let failure = diskutil(verb, bsdName) else { return nil }
        if !userIsAdmin, let elevated = elevatedDiskutil { return elevated(verb, [bsdName]) }
        return failure
    }

    /// Unmounts every Drobo volume. Calls back with the names that could not be ejected.
    /// For a standard account, whatever it was not allowed to unmount is retried once
    /// with a single administrator prompt.
    static func ejectAll(completion: @escaping ([String]) -> Void) {
        let targets = volumes()
        guard !targets.isEmpty else { completion([]); return }
        let group = DispatchGroup()
        let lock = NSLock()
        var failed: [DroboVolume] = []
        for volume in targets {
            group.enter()
            FileManager.default.unmountVolume(at: volume.id, options: [.withoutUI]) { error in
                if error != nil {
                    lock.lock(); failed.append(volume); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            var names = failed.map(\.name)
            if !failed.isEmpty, !userIsAdmin, let elevated = elevatedDiskutil {
                let disks = failed.compactMap { bsdName(ofVolumeAt: $0.id) }
                if !disks.isEmpty {
                    _ = elevated("unmount", disks)
                    // Trust what is still mounted, not what the elevated attempt reported.
                    let remaining = Set(volumes().map(\.id))
                    names = failed.filter { remaining.contains($0.id) }.map(\.name)
                }
            }
            DispatchQueue.main.async { completion(names) }
        }
    }

    private static func bsdName(ofVolumeAt url: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let name = DADiskGetBSDName(disk) else { return nil }
        return String(cString: name)
    }

    /// Whether the logged-in user is in the admin group (gid 80). Admins can mount and
    /// unmount without a prompt, so they are never asked to authenticate.
    private static var userIsAdmin: Bool {
        guard let user = getpwuid(getuid()) else { return false }
        var groups = [Int32](repeating: 0, count: 256)
        var count = Int32(groups.count)
        _ = getgrouplist(user.pointee.pw_name, Int32(user.pointee.pw_gid), &groups, &count)
        return groups.prefix(Int(max(0, min(count, 256)))).contains(80)
    }

    static func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting so a chatty child cannot fill the pipe and stall.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    /// The Drobo's logical units with whatever is mounted from each.
    static func luns(_ snapshot: DroboSnapshot, volumes: [DroboVolume]) -> [DroboLUN] {
        let disks = wholeDisks()
        return snapshot.lunBlocks.enumerated().compactMap { index, blocks in
            guard blocks > 1 else { return nil }
            return DroboLUN(id: index,
                            bytes: blocks * 512,
                            volumeNames: volumes.filter { $0.lun == index }.map(\.name),
                            bsdName: disks[index],
                            writable: snapshot.writableMask & (1 << UInt32(index)) != 0)
        }
    }

    /// Sends one command to the driver. Returns nil on success, or a short reason.
    static func send(_ command: DroboCommand, argument: UInt32 = 0, name: String = "") -> String? {
        guard let service = driverService() else { return "The driver is not running." }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == KERN_SUCCESS else {
            return "Could not connect to the driver (0x" + String(UInt32(bitPattern: opened), radix: 16) + ")."
        }
        defer { IOServiceClose(connection) }

        // Layout must match DroboAppCommandInput in the driver: u32, u32, char[32].
        var input = [UInt8](repeating: 0, count: 40)
        withUnsafeBytes(of: command.rawValue.littleEndian) { input.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: argument.littleEndian) { input.replaceSubrange(4..<8, with: $0) }
        let nameBytes = Array(name.utf8.prefix(31))
        input.replaceSubrange(8..<(8 + nameBytes.count), with: nameBytes)

        let result = IOConnectCallStructMethod(connection, 0, input, input.count, nil, nil)
        switch result {
        case KERN_SUCCESS: return nil
        case kIOReturnBusy: return "The Drobo is busy. Eject its volumes and try again."
        case kIOReturnNotReady: return "The Drobo is not ready yet."
        case kIOReturnNotPermitted: return "The driver refused: the Drobo's own status does not allow this command on that bay now, or that status is not fresh (it must be newer than 15 seconds, and a minute must pass after another per-bay command). Nothing was sent."
        case kIOReturnNotPrivileged: return "The driver refused: the command was not confirmed."
        default: return "The driver refused the command (0x" + String(UInt32(bitPattern: result), radix: 16) + ")."
        }
    }

    /// End-to-end check of the write path on one mounted, writable volume: writes 64 MB of
    /// random data bypassing the file cache, forces it to the Drobo, reads it back from the
    /// Drobo and compares hashes. The test file is removed afterwards. Returns a result line.
    static func writeTest(on volume: URL) -> String {
        let path = volume.appendingPathComponent(".drobo-write-test-\(UUID().uuidString).bin").path
        let chunkSize = 1 << 20
        let chunks = 64
        defer { unlink(path) }

        let fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard fd >= 0 else { return "Write test failed: could not create a file (\(String(cString: strerror(errno))))." }
        _ = fcntl(fd, F_NOCACHE, 1)
        var written = SHA256()
        let start = Date()
        for _ in 0..<chunks {
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            _ = SecRandomCopyBytes(kSecRandomDefault, chunkSize, &chunk)
            written.update(data: chunk)
            let result = chunk.withUnsafeBytes { write(fd, $0.baseAddress, chunkSize) }
            if result != chunkSize {
                close(fd)
                return "Write test failed while writing (\(String(cString: strerror(errno))))."
            }
        }
        if fcntl(fd, F_FULLFSYNC) != 0 {
            close(fd)
            return "Write test failed: the Drobo did not confirm the flush (\(String(cString: strerror(errno))))."
        }
        let writeSeconds = Date().timeIntervalSince(start)
        close(fd)

        let readFD = open(path, O_RDONLY)
        guard readFD >= 0 else { return "Write test failed: could not reopen the file." }
        defer { close(readFD) }
        _ = fcntl(readFD, F_NOCACHE, 1)
        var readBack = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var total = 0
        let readStart = Date()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(readFD, $0.baseAddress, chunkSize) }
            if count < 0 { return "Write test failed while reading back (\(String(cString: strerror(errno))))." }
            if count == 0 { break }
            readBack.update(data: buffer[0..<count])
            total += count
        }
        let readSeconds = Date().timeIntervalSince(readStart)
        guard total == chunkSize * chunks, written.finalize() == readBack.finalize() else {
            return "WRITE TEST FAILED: the data read back does not match what was written. Turn writing off for this volume."
        }
        let megabytes = Double(chunks)
        return String(format: "Write test passed: 64 MB written at %.0f MB/s and read back identical at %.0f MB/s.",
                      megabytes / max(writeSeconds, 0.001), megabytes / max(readSeconds, 0.001))
    }

    // MARK: Diagnostics

    /// Everything the driver publishes, as a JSON-ready dictionary: its counters (`DroboStatus`)
    /// and the raw management pages (`DroboHealth`), with binary data as hex. For bug reports and
    /// as fixture bytes for decoder tests.
    ///
    /// The Drobo's serial number and name are overwritten wherever their bytes appear, in strings
    /// and inside the raw pages, so the page layouts survive but the identifiers do not. Volume
    /// names are never included. Drive model strings are kept.
    static func diagnostics(appVersion: String, commit: String) -> [String: Any] {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        var report: [String: Any] = [
            "format": 1,
            "captured": ISO8601DateFormatter().string(from: Date()),
            "appVersion": appVersion,
            "appCommit": commit,
            "macOS": system,
            "note": "Serial number and Drobo name are redacted. Review before sharing: drive model strings are included.",
        ]
        guard let properties = driverProperties() else {
            report["driver"] = "not running"
            return report
        }
        let current = snapshot()
        // Drive serial numbers (from the optional slot page) are removed as well.
        let secrets = ([current.serial, current.name] + current.slots.map(\.serial)).filter { $0.count >= 3 }
        var driver: [String: Any] = [:]
        for key in ["DroboStatus", "DroboHealth", "IOUserClass", "CFBundleIdentifier", "IOPCIMatch"] {
            if let value = properties[key] { driver[key] = jsonReady(value, redacting: secrets) }
        }
        report["driver"] = driver
        report["decoded"] = [
            "ready": current.ready,
            "stage": current.stage,
            "firmware": current.firmware,
            "statusFlags": current.statusFlags.map { String(format: "0x%08X", $0) } ?? "none",
            "statusLines": current.statusLines,
            "relayoutCount": current.relayoutCount,
            "slots": current.slots.map {
                ["bay": $0.id, "status": $0.statusText, "statusCode": Int($0.statusCode), "model": $0.model,
                 "temperature": $0.temperature ?? -1, "errorCount": $0.errorCount ?? -1, "firmwareRevision": $0.firmwareRevision,
                 "diskState": Int($0.diskState ?? 0), "diskStateText": $0.diskStateText ?? "", "diskType": $0.diskType ?? -1,
                 "lifeRemaining": $0.lifeRemaining ?? -1, "rotationalSpeed": $0.rotationalSpeed ?? -1] as [String: Any]
            },
            "lunBlocks": current.lunBlocks,
            "systemTemperature": current.systemTemperature ?? -1,
            "uptime": Int(current.uptime ?? 0),
            "fanLevels": current.fanLevels.map { Int($0) },
            "fanHealth": current.fanHealth ?? -1,
            "powerHealth": current.powerHealth,
            "deviceIOPS": Int(current.deviceIOPS ?? 0),
            "deviceReadThroughput": Int(current.deviceReadThroughput ?? 0),
            "deviceWriteThroughput": Int(current.deviceWriteThroughput ?? 0),
        ] as [String: Any]
        return report
    }

    static func jsonReady(_ value: Any, redacting secrets: [String]) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { jsonReady($0, redacting: secrets) }
        case let array as [Any]:
            return array.map { jsonReady($0, redacting: secrets) }
        case let data as Data:
            var bytes = [UInt8](data)
            for secret in secrets {
                let pattern = Array(secret.utf8)
                guard bytes.count >= pattern.count else { continue }
                var index = 0
                while index <= bytes.count - pattern.count {
                    if Array(bytes[index..<(index + pattern.count)]) == pattern {
                        for offset in 0..<pattern.count { bytes[index + offset] = 0x58 }   // "X"
                        index += pattern.count
                    } else {
                        index += 1
                    }
                }
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        case let string as String:
            return secrets.reduce(string) { $0.replacingOccurrences(of: $1, with: String(repeating: "X", count: $1.count)) }
        case let number as NSNumber:
            return number
        default:
            return String(describing: value)
        }
    }

    // MARK: Registry access

    static func driverService() -> io_service_t? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOUserSCSIParallelInterfaceController")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let userClass = IORegistryEntryCreateCFProperty(service, "IOUserClass" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, userClass == "DroboSCSIController" {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    private static func driverProperties() -> [String: Any]? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOUserSCSIParallelInterfaceController")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  properties["IOUserClass"] as? String == "DroboSCSIController" else { continue }
            return properties
        }
        return nil
    }

    // MARK: Decoding helpers

    private static func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    /// Strips the 4-byte page header and returns the payload bytes.
    private static func payload(_ value: Any?) -> [UInt8]? {
        guard let data = value as? Data, data.count > 4 else { return nil }
        return Array(data.dropFirst(4))
    }

    private static func be16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    private static func be64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[offset + $1]) }
    }

    private static func string(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String {
        guard offset + length <= bytes.count else { return "" }
        let slice = bytes[offset..<(offset + length)].prefix { $0 != 0 }
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
