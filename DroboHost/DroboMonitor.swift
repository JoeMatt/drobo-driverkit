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
        case 1: return "Red: failed"
        case 2: return "Yellow: replace soon"
        case 3: return "Green: healthy"
        case 4: return "Blinking yellow/green: rebuilding, do not remove"
        case 5: return "Red/yellow"
        case 6: return "Blinking red: failed, replace"
        default: return "Unknown (\(statusCode))"
        }
    }
}

struct DroboVolume: Identifiable {
    let id: URL
    let name: String
    let totalBytes: Int64
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

    /// Mounted volumes whose disk reports "Drobo" as its vendor (the driver's INQUIRY data).
    static func volumes() -> [DroboVolume] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  let vendor = description[kDADiskDescriptionDeviceVendorKey as String] as? String,
                  vendor.trimmingCharacters(in: .whitespaces) == "Drobo" else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return DroboVolume(id: url,
                               name: values?.volumeName ?? url.lastPathComponent,
                               totalBytes: Int64(values?.volumeTotalCapacity ?? 0))
        }
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

    // MARK: Registry access

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
