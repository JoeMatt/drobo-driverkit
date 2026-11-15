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
        let models = ["WDC WD80EFAX", "WDC WD80EFAX", "ST8000VN004", "ST8000VN004", "WDC WD40EFRX", "WDC WD40EFRX"]
        snapshot.slots = (0..<8).map { bay in
            guard bay < models.count else { return DroboSlot(id: bay, physicalBytes: 0, statusCode: 0x80, model: "") }
            let code: UInt8 = rebuilding && bay == 2 ? 4 : 3
            return DroboSlot(id: bay, physicalBytes: (bay < 4 ? 8 : 4) * tb, statusCode: code, model: models[bay])
        } + [DroboSlot(id: 8, physicalBytes: 0, statusCode: 0x80, model: "")]
        data.snapshot = snapshot
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
