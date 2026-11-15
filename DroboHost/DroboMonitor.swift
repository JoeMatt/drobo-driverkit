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
    var statusFlags: UInt32?
    var relayoutCount: UInt32 = 0
    var freeBytes: UInt64?
    var usedBytes: UInt64?
    var totalBytes: UInt64?
    var unprotectedBytes: UInt64?
    var slots: [DroboSlot] = []

    var statusLines: [String] {
        guard let flags = statusFlags else { return [] }
        let table: [(UInt32, String)] = [
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
                                       model: vendor.isEmpty ? product : vendor + " " + product))
                offset += recordSize
            }
            snapshot.slots = slots
        }
        return snapshot
    }

    /// Mounted volumes that live on one of the Drobo's logical units.
    static func volumes() -> [DroboVolume] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey]
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
                               lun: lun)
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

    /// Mounts or unmounts every volume on one of the Drobo's disks. Returns nil on success.
    static func setMounted(_ mounted: Bool, bsdName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = [mounted ? "mountDisk" : "unmountDisk", bsdName]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Could not run diskutil."
        }
        if process.terminationStatus == 0 { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unmounts every Drobo volume. Calls back with the names that could not be ejected.
    static func ejectAll(completion: @escaping ([String]) -> Void) {
        let targets = volumes()
        guard !targets.isEmpty else { completion([]); return }
        let group = DispatchGroup()
        let lock = NSLock()
        var failures: [String] = []
        for volume in targets {
            group.enter()
            FileManager.default.unmountVolume(at: volume.id, options: [.withoutUI]) { error in
                if error != nil {
                    lock.lock(); failures.append(volume.name); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(failures) }
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

    // MARK: Registry access

    private static func driverService() -> io_service_t? {
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
