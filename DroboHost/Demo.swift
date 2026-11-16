import Foundation

/// Made-up dashboard data, so the UI can be worked on and reviewed without a Drobo.
///
/// Launch with `-demo healthy` or `-demo rebuilding`. Nothing is read from or sent to a driver
/// in this mode, and the header is tagged "Demo data". Never enabled unless that argument is
/// passed.
enum Demo {
    static var scenario: String? {
        guard let value = UserDefaults.standard.string(forKey: "demo"), !value.isEmpty else { return nil }
        return value
    }

    struct Data {
        var snapshot = DroboSnapshot()
        var volumes: [DroboVolume] = []
        var luns: [DroboLUN] = []
        var readRate: Double = 0
        var writeRate: Double = 0
        var rebuildETA = ""
    }

    static func data(_ scenario: String) -> Data {
        let rebuilding = scenario == "rebuilding"
        let tb: UInt64 = 1_000_000_000_000
        var data = Data()
        var snapshot = DroboSnapshot()
        snapshot.driverPresent = true
        snapshot.ready = true
        snapshot.healthAvailable = true
        snapshot.name = "Studio Array"
        snapshot.serial = "DRB000000000000"
        snapshot.firmware = "1.2.3"
        snapshot.statusFlags = rebuilding ? 0x0240 : 0
        snapshot.relayoutCount = rebuilding ? 18_420 : 0
        snapshot.usedBytes = 7_420 * (tb / 1000)
        snapshot.freeBytes = 14_180 * (tb / 1000)
        snapshot.totalBytes = 21_600 * (tb / 1000)
        snapshot.dualDiskRedundancy = false
        snapshot.spinDownMinutes = 15
        snapshot.reads = 184_302
        snapshot.writes = 1_204
        snapshot.flushes = 37
        snapshot.errors = 0
        snapshot.firmwareBuild = "Jan 01 2020,12:00:00"
        snapshot.firmwarePlatform = "ArmMarvell"
        snapshot.yellowThreshold = 85
        snapshot.redThreshold = 95
        snapshot.latency = [
            DroboLatency(id: "4 KB", count: 96_210, averageMicroseconds: 310, maxMicroseconds: 48_200),
            DroboLatency(id: "64 KB", count: 41_870, averageMicroseconds: 940, maxMicroseconds: 61_500),
            DroboLatency(id: "256 KB", count: 30_112, averageMicroseconds: 2_860, maxMicroseconds: 88_000),
            DroboLatency(id: "512 KB", count: 17_314, averageMicroseconds: 5_420, maxMicroseconds: 131_000),
        ]
        let models = ["WDC WD80EFAX", "WDC WD80EFAX", "ST8000VN004", "ST8000VN004", "WDC WD40EFRX", "WDC WD40EFRX"]
        snapshot.slots = (0..<8).map { bay in
            guard bay < models.count else { return DroboSlot(id: bay, physicalBytes: 0, statusCode: 0x80, model: "") }
            let code: UInt8 = rebuilding && bay == 2 ? 4 : 3
            let size = (bay < 4 ? 8 : 4) * tb
            var slot = DroboSlot(id: bay, physicalBytes: size, statusCode: code, model: models[bay],
                                 managedBytes: size - 12_000_000_000, interface: "SATA")
            slot.temperature = 33 + (bay * 7) % 9
            slot.lifeRemaining = 100
            slot.rotationalSpeed = bay < 4 ? 27 : 36
            slot.diskType = 0
            slot.diskState = rebuilding && bay == 2 ? 0x12 : (bay == 4 ? 0x11 : 0x10)
            slot.errorCount = rebuilding && bay == 2 ? 14 : 0
            slot.firmwareRevision = bay < 2 ? "81.00A81" : (bay < 4 ? "SC61" : "82.00A82")
            slot.serial = "DEMO\(1000 + bay * 137)"
            return slot
        } + [DroboSlot(id: 8, physicalBytes: 0, statusCode: 0x80, model: "")]
        snapshot.unprotectedBytes = 0
        snapshot.extendedEnabled = true
        snapshot.commandFormat = 3
        snapshot.dimLevel = 2
        snapshot.systemTemperature = 36
        snapshot.uptime = 84 * 86_400 + 2 * 3600 + 51 * 60
        snapshot.fanLevels = [3, 3]
        data.snapshot = snapshot
        data.volumes = [
            DroboVolume(id: URL(fileURLWithPath: "/Volumes/Archive"), name: "Archive", totalBytes: 16_000_000_000_000, lun: 0, availableBytes: 11_200_000_000_000),
            DroboVolume(id: URL(fileURLWithPath: "/Volumes/Media"), name: "Media", totalBytes: 16_000_000_000_000, lun: 1, availableBytes: 13_900_000_000_000),
            DroboVolume(id: URL(fileURLWithPath: "/Volumes/Backups"), name: "Backups", totalBytes: 16_000_000_000_000, lun: 2, availableBytes: 15_100_000_000_000),
        ]
        data.luns = [
            DroboLUN(id: 0, bytes: 16 * tb, volumeNames: ["Archive"], bsdName: nil, writable: false),
            DroboLUN(id: 1, bytes: 16 * tb, volumeNames: ["Media"], bsdName: nil, writable: true),
            DroboLUN(id: 2, bytes: 16 * tb, volumeNames: ["Backups"], bsdName: nil, writable: false),
            DroboLUN(id: 3, bytes: 16 * tb, volumeNames: [], bsdName: nil, writable: false),
        ]
        data.readRate = 86_400_000
        data.writeRate = rebuilding ? 0 : 12_300_000
        data.rebuildETA = rebuilding ? "about 3h 20m left" : ""
        return data
    }
}
