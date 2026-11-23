//
//  DroboProtocol.h
//
//  Wire-level definitions for the Drobo Thunderbolt host protocol, reconstructed from
//  DroboTBT.kext 1.4. See docs/01-protocol-reverse-engineering.md for evidence and
//  confidence levels. Nothing here has been validated against hardware yet.
//
//  All fields are little-endian.
//

#ifndef DroboProtocol_h
#define DroboProtocol_h

#include <stdint.h>

// MARK: PCI identity

static const uint16_t kDroboPCIVendorID   = 0x4452;   // "DR"
static const uint16_t kDrobo8DPCIDeviceID = 0x3844;   // "8D"
static const uint16_t kDroboTBPCIDeviceID = 0x5570;   // "Up": other Thunderbolt models, untested

// MARK: BAR0 (register window)

static const uint32_t kDroboRegIncomingDoorbellCause = 0x21878;
static const uint32_t kDroboHostBarReadyBit          = 0x00200000;   // bit 21
static const uint32_t kDroboRegIncomingDoorbellMask  = 0x2187C;      // firmware-owned; 0x0C23FFFF once it is listening
static const uint32_t kDroboRegOutgoingDoorbellCause = 0x21870;
static const uint32_t kDroboRegOutgoingDoorbellMask  = 0x21874;

// MARK: DMA constraints used by the original driver

static const uint8_t  kDroboDMAAddressBits    = 32;
static const uint64_t kDroboDMAMaxSegmentSize = 0x80000;    // 512 KiB
static const uint64_t kDroboDMAMaxTransfer    = 0x100000;   // 1 MiB

// MARK: BAR1 ("DroboPort" shared-memory region). Offsets are relative to BAR1.

#define kDroboPortSignature "DroboPort"
static const uint32_t kDroboPortSignatureLength = 16;

// Observed on hardware: register window = config BAR0 (1 MiB), DroboPort = config BAR2 (64 KiB).
static const uint8_t kDroboRegisterBAR  = 0;
static const uint8_t kDroboPortBAR      = 2;

enum DroboPortOffset : uint32_t {
    kDroboPortSignatureOffset      = 0x00,
    kDroboPortLUNTableOffset       = 0x18,
    kDroboPortCapabilitiesOffset   = 0x1C,
    kDroboPortSCSIRequestOffset    = 0x20,
    kDroboPortSCSIResponseOffset   = 0x24,
    kDroboPortSysRequestOffset     = 0x28,
    kDroboPortSysResponseOffset    = 0x2C,
    kDroboPortTMRequestOffset      = 0x30,
    kDroboPortTMResponseOffset     = 0x34,
    kDroboPortInterruptInOffset    = 0x38,
    kDroboPortInterruptOutOffset   = 0x3C,
    kDroboPortSerialNumberOffset   = 0x40,   // 0xFFFFFFFF if absent
};

struct DroboPortCapabilities {
    uint32_t interfaceVersion;
    uint32_t transferMode;
    uint32_t maxTransferSize;
    uint32_t maxOutstandingTransactions;
    uint32_t maxLUNs;
    uint32_t portFlags;
    uint32_t maxBurstSize;
    uint32_t stallSize;
    uint32_t maxSGLEntries;
    uint32_t hostInterfaceVersion;   // written by the host (1)
    uint32_t unknown[6];
};
_Static_assert(sizeof(DroboPortCapabilities) == 0x40, "capabilities layout");

struct DroboLUNEntry {
    uint32_t present;       // 1 when the LUN exists (observed)
    uint32_t blockSize;     // 0x200 observed
    uint64_t blockCount;    // also the upper bound used for LBA range checks
};
_Static_assert(sizeof(DroboLUNEntry) == 0x10, "LUN entry layout");

// MARK: Self-describing doorbell tables

enum DroboRegOperator : uint32_t {
    kDroboRegOpAnd  = 0,
    kDroboRegOpOr   = 1,
    kDroboRegOpXor  = 2,
    kDroboRegOpSet  = 3,
    kDroboRegOpNone = 4,
};

struct DroboRegAction {
    uint32_t offset;     // relative to BAR0
    uint32_t size;
    uint32_t value;
    uint32_t op;         // DroboRegOperator
};

struct DroboInterruptDef {
    uint32_t       unknown;
    DroboRegAction trigger;
    DroboRegAction state;
    DroboRegAction enable;
    DroboRegAction disable;
    DroboRegAction clear;
};
_Static_assert(sizeof(DroboInterruptDef) == 0x54, "interrupt definition layout");

static const uint32_t kDroboInterruptTableHeaderSize = 0x24;   // 9 x u32
static const uint32_t kDroboInterruptInCount         = 7;
static const uint32_t kDroboInterruptOutCount        = 6;

enum DroboInterruptIn : uint32_t {      // host -> Drobo
    kDroboIntInSCSIRequestReady = 0,
    kDroboIntInSysRequestReady  = 3,
    kDroboIntInTMRequestReady   = 4,
    kDroboIntInDriverReady      = 5,
};

enum DroboInterruptOut : uint32_t {     // Drobo -> host
    kDroboIntOutSCSIResponseReady = 0,
    kDroboIntOutTMResponseReady   = 1,
    kDroboIntOutSysResponseReady  = 2,
    kDroboIntOutAdapterReady      = 4,
    kDroboIntOutSummary           = 5,  // interface version >= 3 only
};

// MARK: Request / response queues (in BAR1)

struct DroboQueueEntry {
    uint32_t requestAddressLow;
    uint32_t requestAddressHigh;
    uint32_t requestLength;
    uint32_t transactionID;
};
_Static_assert(sizeof(DroboQueueEntry) == 0x10, "queue entry layout");

struct DroboRequestListHeader {
    uint32_t windowSize;     // read by the host
    uint32_t entryCount;     // written by the host before ringing the doorbell
    // DroboQueueEntry entries[] follow
};

struct DroboResponseEntryV1 {            // interface version < 4
    uint32_t queueIndex;
    uint32_t transactionID;
};

struct DroboResponseEntryV4 {            // interface version >= 4
    uint32_t queueIndex;
    uint32_t transactionID;
    uint64_t bytesTransferred;
    uint32_t unknown0;
    uint32_t srbResponse;
    uint32_t scsiStatus;
    uint32_t unknown1;
};
_Static_assert(sizeof(DroboResponseEntryV4) == 0x20, "response entry layout");

static const uint32_t kDroboResponseListCountOffset   = 0x04;
static const uint32_t kDroboResponseListEntriesOffset = 0x08;
static const uint32_t kDroboResponseListSize          = 0x108;

static const uint32_t kDroboSRBResponseSuccess = 0x01;
static const uint32_t kDroboSRBResponseShort   = 0x12;   // accepted as success by the kext

// MARK: Request structures (host memory, read by the Drobo via DMA)

static const uint32_t kDroboMaxSGLEntries = 512;

struct DroboSGLEntry {
    uint64_t address;    // bus address, must fit in 32 bits
    uint32_t length;     // 0 terminates the list
    uint32_t unused;
};
_Static_assert(sizeof(DroboSGLEntry) == 0x10, "SGL entry layout");

enum DroboRequestKind : uint32_t {
    kDroboRequestKindBlockIO     = 1,
    kDroboRequestKindSystem      = 2,     // header + one u32 command word, total length 0x28
    kDroboRequestKindPassthrough = 3,
};

enum DroboSystemCommand : uint32_t {
    kDroboSystemCommandStartStop = 3,     // sent by the kext for START STOP UNIT
    kDroboSystemCommandFlush     = 5,     // sent for SYNCHRONIZE CACHE (and WRITE BUFFER)
};

enum DroboBlockOperation : uint32_t {
    kDroboBlockOpNoData = 0x00400030,
    kDroboBlockOpWrite  = 0x00400031,
    kDroboBlockOpRead   = 0x00400032,
};

enum DroboPassthroughFlags : uint32_t {
    kDroboPassthroughDataInOrNone = 0x00410020,
    kDroboPassthroughDataOut      = 0x00420020,
    // Exactly one of these is OR-ed in when the request carries data:
    kDroboPassthroughDirectBuffer = 0x00000008,   // one segment: pointer field = buffer bus address
    kDroboPassthroughSGL          = 0x00000010,   // several: SGL follows the request at +0x58
};

struct DroboRequestHeader {              // "BaseSrbExtension"
    uint64_t hostDataBusAddress;
    uint32_t queueIndex;
    uint32_t transactionIDCopy;
    uint64_t hostCookie;
    uint32_t totalLength;
    uint32_t kind;                       // DroboRequestKind
};
_Static_assert(sizeof(DroboRequestHeader) == 0x20, "request header layout");

struct DroboBlockRequest {               // "DroboSCSISrbExtension" minus the SGL
    DroboRequestHeader header;           // 0x00
    uint8_t  unknown0[0x10];             // 0x20
    uint32_t operation;                  // 0x30  DroboBlockOperation
    uint32_t transferLength;             // 0x34  bytes
    uint64_t hostSGLPointer;             // 0x38
    uint32_t lun;                        // 0x40
    uint32_t unknown1;                   // 0x44
    uint32_t blockCount;                 // 0x48
    uint32_t unknown2;                   // 0x4C
    uint64_t lba;                        // 0x50
    uint64_t unknown3;                   // 0x58
    uint64_t transactionID;              // 0x60
    uint32_t unknown4;                   // 0x68
    uint32_t responseBytesTransferred;   // 0x6C  (interface < 4)
    uint32_t unknown5;                   // 0x70
    uint32_t responseSRBResponse;        // 0x74  (interface < 4)
    uint32_t responseSCSIStatus;         // 0x78  (interface < 4)
    uint32_t unknown6;                   // 0x7C
    // DroboSGLEntry sgl[] follows at 0x80
};
_Static_assert(sizeof(DroboBlockRequest) == 0x80, "block request layout");

struct DroboPassthroughRequest {         // "TransportManagerSrbExtension" minus the SGL
    DroboRequestHeader header;           // 0x00
    uint32_t flags;                      // 0x20  DroboPassthroughFlags
    uint32_t transferLength;             // 0x24
    uint64_t hostSGLPointer;             // 0x28  buffer bus address in direct-buffer mode
    uint8_t  cdb[16];                    // 0x30
    uint32_t responseBytesTransferred;   // 0x40
    uint32_t unknown0[2];                // 0x44
    uint32_t responseSRBResponse;        // 0x4C
    uint32_t responseSCSIStatus;         // 0x50
    uint32_t unknown1;                   // 0x54
    // DroboSGLEntry sgl[] follows at 0x58
};
_Static_assert(sizeof(DroboPassthroughRequest) == 0x58, "passthrough request layout");

// MARK: The firmware shell (system operation 0x0A, protocol notes 11.22 and 11.24)
//
// The two requests of one shell command, byte for byte as Drobo Dashboard 3.6.1 builds them
// (ESASCSISession::runEsaCommand @ 0x1000a8bcc, which calls ESASystemOperationRequest's
// constructor with the three byte-6 flags 0, 1, 0 for the text and 0, first, 0 for a read).
// Byte 6 is 0x20 here, not the 0x21 of blink, standby and the dim level: checked again in
// 11.24, where it is also shown that the 8D's firmware does not read byte 6 for this
// operation. tests/shell_request_bytes.cpp prints these and compares them with the notes.

static const uint8_t  kDroboOperationShell = 0x0A;
static const uint32_t kDroboShellChunk     = 0x800;     // what Dashboard asks for per read

// The command text, data-out:  EA 10 00 0A <sequence> 00 20 <length16, big-endian> 00
static inline void
DroboShellCommandCDB(uint8_t cdb[16], uint8_t sequence, uint16_t textLength)
{
    for (int i = 0; i < 16; i++) {
        cdb[i] = 0;
    }
    cdb[0] = 0xEA;
    cdb[1] = 0x10;
    cdb[3] = kDroboOperationShell;
    cdb[4] = sequence;
    cdb[6] = 0x20;
    cdb[7] = (uint8_t) (textLength >> 8);
    cdb[8] = (uint8_t) textLength;
}

// One read of its output, data-in, with the sequence number the text went out with:
//   EA 10 80 0A <sequence> 00 <20 on the first read, 00 after> 08 00 00
static inline void
DroboShellReadCDB(uint8_t cdb[16], uint8_t sequence, bool first)
{
    for (int i = 0; i < 16; i++) {
        cdb[i] = 0;
    }
    cdb[0] = 0xEA;
    cdb[1] = 0x10;
    cdb[2] = 0x80;
    cdb[3] = kDroboOperationShell;
    cdb[4] = sequence;
    cdb[6] = first ? 0x20 : 0x00;
    cdb[7] = (uint8_t) (kDroboShellChunk >> 8);
    cdb[8] = (uint8_t) kDroboShellChunk;
}

// MARK: Volume management and reset (protocol notes 11.26)
//
// The four system operations Drobo Dashboard 3.6.1 uses to create and delete volumes and to
// reset (erase) the whole unit, byte for byte as its service builds them, and checked against
// the 8D firmware's own handler for each (HAManager::systemOperation). All four are
// destructive or lead to something destructive; the driver sends them only through
// DroboSCSIController::VolumeCommand, which holds the checks. tests/volume_request_bytes.cpp
// prints these and compares them with the notes.

static const uint8_t kDroboOperationResetPack    = 0x02;    // "format ESA": erase everything, restart
static const uint8_t kDroboOperationVolumeSize   = 0x0F;    // "resize LUNs": set the volume size; a change erases everything
static const uint8_t kDroboOperationCreateVolume = 0x12;
static const uint8_t kDroboOperationDeleteVolume = 0x13;
static const uint8_t kDroboOperationNextVolumeID = 0x20;    // hands out the next unique volume ID

static const uint32_t kDroboCreateVolumeLength = 12;
static const uint32_t kDroboDeleteVolumeLength = 4;
static const uint32_t kDroboNextVolumeIDLength = 2;
static const uint32_t kDroboVolumeSizeLength   = 4;
static const uint32_t kDroboVolumeSizeMaxTiB   = 128;       // the largest size Dashboard's own menu offers

// Volume size: u32, big-endian, in TiB. This is the Drobo-wide size of the volume it makes
// for itself. When it differs from the disk pack's, the firmware erases the pack and
// restarts, exactly as for a reset (protocol notes 11.27).
static inline void
DroboVolumeSizePayload(uint8_t payload[4], uint32_t tib)
{
    payload[0] = (uint8_t) (tib >> 24);
    payload[1] = (uint8_t) (tib >> 16);
    payload[2] = (uint8_t) (tib >> 8);
    payload[3] = (uint8_t) tib;
}

// A system operation:  EA 10 <80 when it reads data back> <operation> <sequence> 00 21 <length16> 00
// (protocol notes 11.14). Dashboard sends a counter in byte 4 for the operations that go
// through its session object (reset among them) and zero for the three volume operations.
static inline void
DroboSystemOperationCDB(uint8_t cdb[16], uint8_t operation, uint8_t sequence, uint16_t length, bool dataIn)
{
    for (int i = 0; i < 16; i++) {
        cdb[i] = 0;
    }
    cdb[0] = 0xEA;
    cdb[1] = 0x10;
    cdb[2] = dataIn ? 0x80 : 0x00;
    cdb[3] = operation;
    cdb[4] = sequence;
    cdb[6] = 0x21;
    cdb[7] = (uint8_t) (length >> 8);
    cdb[8] = (uint8_t) length;
}

// Create: u64 size in bytes (big-endian; the firmware turns it into a last block number),
// a flags byte (bit 0 is passed on to the firmware's volume table; Dashboard passes its
// request's Flags value, this driver always sends 0), a byte that makes the firmware drop its
// USB connection when not zero (always 0), u16 unique volume ID (big-endian).
static inline void
DroboCreateVolumePayload(uint8_t payload[12], uint64_t sizeBytes, uint16_t uniqueID)
{
    for (int i = 0; i < 8; i++) {
        payload[i] = (uint8_t) (sizeBytes >> (56 - 8 * i));
    }
    payload[8]  = 0;
    payload[9]  = 0;
    payload[10] = (uint8_t) (uniqueID >> 8);
    payload[11] = (uint8_t) uniqueID;
}

// Delete: u16 unique volume ID (big-endian), the unit number, and the same "drop the USB
// connection" byte (always 0).
static inline void
DroboDeleteVolumePayload(uint8_t payload[4], uint16_t uniqueID, uint8_t unit)
{
    payload[0] = (uint8_t) (uniqueID >> 8);
    payload[1] = (uint8_t) uniqueID;
    payload[2] = unit;
    payload[3] = 0;
}

// The volume list: management page 0x07 (ESALUNInfo2). After the 4-byte page header comes a
// count byte, then 19-byte records. The 8D sends a record for every unit it could have (16).
// A unit that never held a volume has unique ID 0; a unit whose volume was deleted keeps its
// record and its ID but has size 0 (protocol notes 11.26, "On hardware"). So a record is a
// volume when both its unique ID and its size are not 0. The count byte counts deleted units
// too and is not relied on.
static const uint32_t kDroboVolumePageHeader = 5;
static const uint32_t kDroboVolumeRecordSize = 19;

struct DroboVolumeRecord {
    uint8_t  unit;              // +2   the logical unit number
    uint64_t sizeBytes;         // +3   u64, big-endian
    uint8_t  partitionScheme;   // +11
    uint8_t  partitionCount;    // +12
    uint8_t  formatType;        // +13
    uint16_t uniqueID;          // +14  u16, big-endian: what delete is keyed by
    uint16_t nextID;            // +16  u16, big-endian: the next ID the Drobo would hand out
};

// How many whole records the page holds, in use or not.
static inline uint32_t
DroboVolumePageCount(const uint8_t * page, uint32_t length)
{
    if (page == nullptr || length < kDroboVolumePageHeader || page[0] != 0x7A) {
        return 0;
    }
    return (length - kDroboVolumePageHeader) / kDroboVolumeRecordSize;
}

static inline bool
DroboVolumeRecordInUse(const DroboVolumeRecord * record)
{
    return record->uniqueID != 0 && record->sizeBytes != 0;
}

static inline bool
DroboVolumePageRecord(const uint8_t * page, uint32_t length, uint32_t index, DroboVolumeRecord * record)
{
    if (index >= DroboVolumePageCount(page, length)) {
        return false;
    }
    const uint8_t * r = page + kDroboVolumePageHeader + index * kDroboVolumeRecordSize;
    record->unit = r[2];
    record->sizeBytes = 0;
    for (int i = 0; i < 8; i++) {
        record->sizeBytes = (record->sizeBytes << 8) | r[3 + i];
    }
    record->partitionScheme = r[11];
    record->partitionCount  = r[12];
    record->formatType      = r[13];
    record->uniqueID = (uint16_t) ((r[14] << 8) | r[15]);
    record->nextID   = (uint16_t) ((r[16] << 8) | r[17]);
    return true;
}

#endif /* DroboProtocol_h */
