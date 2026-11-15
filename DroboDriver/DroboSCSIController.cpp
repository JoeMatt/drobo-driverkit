//
//  DroboSCSIController.cpp
//
//  Read-only driver for the Drobo 8D.
//
//  What this driver does to the hardware:
//    - enables PCI memory space and bus mastering, and one MSI vector;
//    - performs the HOST_BAR_READY handshake and waits for the firmware ("adapter ready");
//    - writes Host Interface Version = 1 into the DroboPort capabilities;
//    - sends READ requests on the block I/O channel, up to 32 at a time in bursts, and
//      completes them from the interrupt handler (a timer is the fallback).
//  What it never does:
//    - send a write of any kind. WRITE/UNMAP/FORMAT etc. are rejected in the driver with
//      DATA PROTECT, and MODE SENSE reports the medium as write-protected;
//    - use the passthrough or system-control channels. INQUIRY, READ CAPACITY, REPORT LUNS,
//      MODE SENSE and friends are answered from data the Drobo already published.
//
//  State is published under the "DroboStatus" registry property:
//    ioreg -r -c IOUserSCSIParallelInterfaceController -l -w0 | grep DroboStatus
//

#include <os/log.h>

#include <DriverKit/DriverKit.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOKitKeys.h>
#include <DriverKit/IOInterruptDispatchSource.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <DriverKit/OSCollections.h>
#include <PCIDriverKit/PCIDriverKit.h>

#include "DroboProtocol.h"
#include "DroboSCSIController.h"

#define DLog(fmt, ...) do { os_log(OS_LOG_DEFAULT, "Drobo: " fmt, ##__VA_ARGS__); IOLog("Drobo: " fmt "\n", ##__VA_ARGS__); } while (0)

// Standard PCI configuration header offsets.
enum : uint64_t {
    kCfgVendorID   = 0x00,
    kCfgDeviceID   = 0x02,
    kCfgCommand    = 0x04,
    kCfgStatus     = 0x06,
    kCfgRevClass   = 0x08,
    kCfgHeaderType = 0x0E,
    kCfgBAR0       = 0x10,
    kCfgSubVendor  = 0x2C,
    kCfgSubDevice  = 0x2E,
    kCfgCapPtr     = 0x34,
    kCfgIntLinePin = 0x3C,
};

struct DroboLUN
{
    bool     present;
    uint32_t blockSize;
    uint64_t blockCount;
};

// Drobo management pages: MODE SENSE(10), page 0x3A, one sub-page each. The formats are those
// documented by the open-source drobo-utils project; the host app decodes them.
static const uint32_t kHealthPageCount = 7;
static const uint32_t kHealthPageMax   = 720;       // slot page: 4 + 1 + 9 x 72
static const uint8_t  kHealthPages[kHealthPageCount] = { 0x01, 0x02, 0x03, 0x05, 0x06, 0x08, 0x09 };
static const uint32_t kHealthSlot      = 32;        // request slot after the 32 block-I/O slots
static const uint32_t kHealthDataOffset = 0x3000;   // data area (4 KiB) inside the request buffer

static const uint32_t kDroboSlotCount   = 32;       // concurrent requests (device allows 64)
static const uint32_t kDroboSlotSize    = 0x100;    // request memory per slot (0x90 used)
static const uint32_t kDroboTaskTimeoutMS = 30000;

struct DroboSlot
{
    bool        inUse;
    bool        submitted;
    uint32_t    transactionID;
    uint64_t    length;
    uint64_t    submitTime;         // mach_absolute_time
    uint64_t    targetID;
    uint64_t    taskID;
    OSAction *  completion;
};

struct DroboSCSIController_IVars
{
    IOPCIDevice *              pciDevice;
    bool                       pciOpen;
    IODispatchQueue *          probeQueue;      // serial queue: bring-up and all device I/O
    IODispatchQueue *          targetQueue;     // target creation only
    IODispatchQueue *          auxiliaryQueue;  // required by SCSIControllerDriverKit ("AuxiliaryQueue")
    IODispatchQueue *          interruptQueue;  // required by SCSIControllerDriverKit ("InterruptQueue")
    bool                       targetCallInFlight;
    uint32_t                   queueResult[6];
    IODispatchQueue *          defaultQueue;
    uint64_t                   statTaskManagement;  // abort / reset callbacks from the family
    uint64_t                   statReceived;    // UserProcessParallelTask calls
    uint64_t                   statCompleted;   // ParallelTaskCompletion returned
    uint32_t                   traceCount;
    uint32_t                   trace[32][6];    // opcode|size|dir, lun, requested, taskID, status, timeout
    uint32_t                   superStartResult;
    uint32_t                   constraintsResult;
    bool                       targetCreated;
    uint32_t                   createTargetResult;
    uint64_t                   statTasks;
    uint8_t                    lastOpcode;
    bool                       stopping;
    bool                       probeDone;

    uint8_t                    regIndex;        // BAR0 memory index
    uint8_t                    portIndex;       // BAR2 memory index
    uint64_t                   portSize;

    uint32_t                   capabilitiesOffset;
    uint32_t                   lunTableOffset;
    uint32_t                   requestListOffset;
    uint32_t                   responseListOffset;
    uint32_t                   interfaceVersion;
    uint32_t                   maxTransferSize;
    uint32_t                   lunCount;
    DroboLUN                   luns[32];
    char                       serial[33];

    IOBufferMemoryDescriptor * requestBuffer;
    IODMACommand *             requestDMA;
    uint8_t *                  requestVA;
    uint64_t                   requestBusAddress;

    // Direct MMIO mappings (nullptr = use the IOPCIDevice accessors).
    IOMemoryMap *              regMap;
    IOMemoryMap *              portMap;
    uint8_t *                  regBase;
    uint8_t *                  portBase;

    // Interrupt and timer sources, both delivered on the serial I/O queue.
    IOInterruptDispatchSource * interruptSource;
    OSAction *                 interruptAction;
    IOTimerDispatchSource *    timerSource;
    OSAction *                 timerAction;
    bool                       timerArmed;
    bool                       deviceInterruptsEnabled;
    uint32_t                   msiIndex;
    uint32_t                   interruptSetupResult;
    uint64_t                   ticksPerMillisecond;

    // Request slots. All of this is only touched on the serial I/O queue.
    DroboSlot                  slots[kDroboSlotCount];
    uint8_t                    pendingRing[kDroboSlotCount];
    uint32_t                   pendingHead;
    uint32_t                   pendingCount;
    uint32_t                   inflight;
    uint32_t                   burstMax;
    uint32_t                   maxInflight;

    uint64_t                   statInterrupts;
    uint64_t                   statTimerFires;
    uint64_t                   statBursts;
    uint64_t                   statCompletedByInterrupt;
    uint64_t                   statCompletedByTimer;
    uint32_t                   statPeakInflight;
    uint32_t                   statPeakBurst;
    uint64_t                   statDoorbellBusy;
    // Request latency (submit to completion) by transfer size: <=4K, <=64K, <=256K, larger.
    uint64_t                   latencyCount[4];
    uint64_t                   latencyTicks[4];
    uint64_t                   latencyMaxTicks[4];
    uint64_t                   lastPublishTicks;

    // Health polling over the passthrough ("TM") channel. I/O queue only.
    IOTimerDispatchSource *    healthTimer;
    OSAction *                 healthAction;
    uint32_t                   tmRequestListOffset;
    uint32_t                   tmResponseListOffset;
    bool                       healthAvailable;
    bool                       tmInflight;
    uint64_t                   tmSubmitTime;
    uint32_t                   healthPage;          // index into kHealthPages
    uint32_t                   healthSlotCount;
    uint64_t                   healthCycles;
    uint64_t                   healthErrors;
    uint32_t                   healthLastSRB;
    uint32_t                   healthLastStatus;
    uint32_t                   healthLength[kHealthPageCount];
    uint8_t                    healthData[kHealthPageCount][kHealthPageMax];

    uint32_t                   nextTransactionID;
    uint32_t                   nextTaskID;
    bool                       ready;
    bool                       dead;

    uint64_t                   statReads;
    uint64_t                   statReadBytes;
    uint64_t                   statErrors;
    uint64_t                   statRejectedWrites;
    uint32_t                   lastSRBResponse;
    uint32_t                   lastSCSIStatus;
    char                       stage[48];
};

// MARK: Lifecycle

bool
DroboSCSIController::init()
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(DroboSCSIController_IVars, 1);
    return ivars != nullptr;
}

void
DroboSCSIController::free()
{
    if (ivars != nullptr) {
        OSSafeReleaseNULL(ivars->interruptSource);
        OSSafeReleaseNULL(ivars->interruptAction);
        OSSafeReleaseNULL(ivars->timerSource);
        OSSafeReleaseNULL(ivars->timerAction);
        OSSafeReleaseNULL(ivars->healthTimer);
        OSSafeReleaseNULL(ivars->healthAction);
        OSSafeReleaseNULL(ivars->regMap);
        OSSafeReleaseNULL(ivars->portMap);
        OSSafeReleaseNULL(ivars->probeQueue);
        OSSafeReleaseNULL(ivars->targetQueue);
        OSSafeReleaseNULL(ivars->auxiliaryQueue);
        OSSafeReleaseNULL(ivars->defaultQueue);
        OSSafeReleaseNULL(ivars->interruptQueue);
        OSSafeReleaseNULL(ivars->requestDMA);
        OSSafeReleaseNULL(ivars->requestBuffer);
        OSSafeReleaseNULL(ivars->pciDevice);
        IOSafeDeleteNULL(ivars, DroboSCSIController_IVars, 1);
    }
    super::free();
}

static const char *
BARTypeName(uint8_t type)
{
    switch (type) {
        case kPCIBARTypeM32:   return "mem32";
        case kPCIBARTypeIO:    return "io";
        case kPCIBARTypeM64:   return "mem64";
        case kPCIBARTypeM32PF: return "mem32-prefetch";
        case kPCIBARTypeM64PF: return "mem64-prefetch";
        default:               return "unknown";
    }
}

static void
LogPCIConfiguration(IOPCIDevice * pci)
{
    uint16_t vendor = 0, device = 0, command = 0, status = 0, subVendor = 0, subDevice = 0;
    uint32_t revClass = 0, intLinePin = 0;
    uint8_t  headerType = 0, capPtr = 0;

    pci->ConfigurationRead16(kCfgVendorID, &vendor);
    pci->ConfigurationRead16(kCfgDeviceID, &device);
    pci->ConfigurationRead16(kCfgCommand, &command);
    pci->ConfigurationRead16(kCfgStatus, &status);
    pci->ConfigurationRead32(kCfgRevClass, &revClass);
    pci->ConfigurationRead8(kCfgHeaderType, &headerType);
    pci->ConfigurationRead16(kCfgSubVendor, &subVendor);
    pci->ConfigurationRead16(kCfgSubDevice, &subDevice);
    pci->ConfigurationRead8(kCfgCapPtr, &capPtr);
    pci->ConfigurationRead32(kCfgIntLinePin, &intLinePin);

    DLog("PCI %04x:%04x subsystem %04x:%04x expected %04x:%04x",
         vendor, device, subVendor, subDevice, kDroboPCIVendorID, kDrobo8DPCIDeviceID);
    DLog("command 0x%04x (io %d, mem %d, busmaster %d) status 0x%04x",
         command, command & 1, (command >> 1) & 1, (command >> 2) & 1, status);
    DLog("class 0x%06x revision 0x%02x header 0x%02x capptr 0x%02x intpin %u",
         revClass >> 8, revClass & 0xFF, headerType, capPtr, (intLinePin >> 8) & 0xFF);

    for (uint8_t bar = 0; bar < 6; bar++) {
        uint32_t raw = 0;
        pci->ConfigurationRead32(kCfgBAR0 + 4 * bar, &raw);

        uint8_t  memoryIndex = 0;
        uint64_t size = 0;
        uint8_t  type = 0;
        kern_return_t ret = pci->GetBARInfo(bar, &memoryIndex, &size, &type);
        if (ret == kIOReturnSuccess) {
            DLog("BAR%u raw 0x%08x memoryIndex %u size 0x%llx type %{public}s",
                 bar, raw, memoryIndex, size, BARTypeName(type));
        } else {
            DLog("BAR%u raw 0x%08x not present (0x%08x)", bar, raw, ret);
        }
    }

    // Walk the capability list so we know whether MSI / MSI-X / PCIe caps are advertised.
    if (status & 0x10) {
        uint8_t offset = capPtr & 0xFC;
        for (int guard = 0; offset >= 0x40 && guard < 48; guard++) {
            uint16_t header = 0;
            pci->ConfigurationRead16(offset, &header);
            DLog("capability id 0x%02x at 0x%02x", header & 0xFF, offset);
            offset = (header >> 8) & 0xFC;
        }
    }
}



// MARK: Small helpers

static void
DictSetNumber(OSDictionary * dict, const char * key, uint64_t value)
{
    OSNumber * number = OSNumber::withNumber(value, 64);
    if (number != nullptr) {
        dict->setObject(key, number);
        number->release();
    }
}

static void
DictSetString(OSDictionary * dict, const char * key, const char * value)
{
    OSString * string = OSString::withCString(value);
    if (string != nullptr) {
        dict->setObject(key, string);
        string->release();
    }
}

// MMIO. When the BARs could be mapped into this process the registers are read and written
// directly; each IOPCIDevice::MemoryRead32/Write32 is otherwise a round trip into the kernel,
// which dominated the per-request cost in the polled version.
static inline uint32_t
Reg32(DroboSCSIController_IVars * iv, uint32_t offset)
{
    if (iv->regBase != nullptr) {
        return *(volatile uint32_t *) (iv->regBase + offset);
    }
    uint32_t value = 0xFFFFFFFF;
    iv->pciDevice->MemoryRead32(iv->regIndex, offset, &value);
    return value;
}

static inline void
RegWrite32(DroboSCSIController_IVars * iv, uint32_t offset, uint32_t value)
{
    if (iv->regBase != nullptr) {
        *(volatile uint32_t *) (iv->regBase + offset) = value;
        return;
    }
    iv->pciDevice->MemoryWrite32(iv->regIndex, offset, value);
}

static inline uint32_t
Port32(DroboSCSIController_IVars * iv, uint32_t offset)
{
    uint32_t value = 0xFFFFFFFF;
    if ((uint64_t) offset + 4 <= iv->portSize) {
        if (iv->portBase != nullptr) {
            return *(volatile uint32_t *) (iv->portBase + offset);
        }
        iv->pciDevice->MemoryRead32(iv->portIndex, offset, &value);
    }
    return value;
}

static inline void
PortWrite32(DroboSCSIController_IVars * iv, uint32_t offset, uint32_t value)
{
    if ((uint64_t) offset + 4 <= iv->portSize) {
        if (iv->portBase != nullptr) {
            *(volatile uint32_t *) (iv->portBase + offset) = value;
            return;
        }
        iv->pciDevice->MemoryWrite32(iv->portIndex, offset, value);
    }
}

// Maps one BAR into this process. Returns nullptr (and the accessors are used) on failure.
static uint8_t *
MapBAR(IOService * service, IOPCIDevice * pci, uint8_t memoryIndex, uint64_t expectedSize, IOMemoryMap ** outMap)
{
    IOMemoryDescriptor * memory = nullptr;
    if (pci->_CopyDeviceMemoryWithIndex(memoryIndex, &memory, service) != kIOReturnSuccess || memory == nullptr) {
        return nullptr;
    }
    IOMemoryMap * map = nullptr;
    kern_return_t ret = memory->CreateMapping(0, 0, 0, 0, 0, &map);
    memory->release();
    if (ret != kIOReturnSuccess || map == nullptr) {
        return nullptr;
    }
    if (map->GetLength() < expectedSize || map->GetAddress() == 0) {
        map->release();
        return nullptr;
    }
    *outMap = map;
    return (uint8_t *) map->GetAddress();
}

static void
SetStage(DroboSCSIController_IVars * iv, const char * stage)
{
    strlcpy(iv->stage, stage, sizeof(iv->stage));
    DLog("stage: %{public}s", stage);
}

static void
PublishStatus(IOService * service, DroboSCSIController_IVars * iv)
{
    OSDictionary * status = OSDictionary::withCapacity(64);
    if (status == nullptr) {
        return;
    }
    DictSetString(status, "Stage", iv->stage);
    status->setObject("Ready", iv->ready ? kOSBooleanTrue : kOSBooleanFalse);
    status->setObject("Dead", iv->dead ? kOSBooleanTrue : kOSBooleanFalse);
    DictSetString(status, "Serial", iv->serial);
    DictSetNumber(status, "InterfaceVersion", iv->interfaceVersion);
    DictSetNumber(status, "MaxTransferSize", iv->maxTransferSize);
    DictSetNumber(status, "RequestBusAddress", iv->requestBusAddress);
    status->setObject("TargetCreated", iv->targetCreated ? kOSBooleanTrue : kOSBooleanFalse);
    DictSetNumber(status, "CreateTargetResult", iv->createTargetResult);
    DictSetNumber(status, "Tasks", iv->statTasks);
    DictSetNumber(status, "ConstraintsResult", iv->constraintsResult);
    DictSetNumber(status, "Received", iv->statReceived);
    DictSetNumber(status, "TaskManagementCalls", iv->statTaskManagement);
    DictSetNumber(status, "Completed", iv->statCompleted);
    OSData * traceData = OSData::withBytes(iv->trace, sizeof(iv->trace[0]) * (iv->traceCount < 32 ? iv->traceCount : 32));
    if (traceData != nullptr) {
        status->setObject("Trace", traceData);
        traceData->release();
    }
    OSData * queueData = OSData::withBytes(iv->queueResult, sizeof(iv->queueResult));
    if (queueData != nullptr) {
        status->setObject("QueueResults", queueData);
        queueData->release();
    }
    DictSetNumber(status, "LastOpcode", iv->lastOpcode);
    status->setObject("DirectMMIO", (iv->regBase != nullptr && iv->portBase != nullptr) ? kOSBooleanTrue : kOSBooleanFalse);
    status->setObject("DeviceInterruptsEnabled", iv->deviceInterruptsEnabled ? kOSBooleanTrue : kOSBooleanFalse);
    DictSetNumber(status, "InterruptSetupResult", iv->interruptSetupResult);
    DictSetNumber(status, "MSIIndex", iv->msiIndex);
    DictSetNumber(status, "Interrupts", iv->statInterrupts);
    DictSetNumber(status, "TimerFires", iv->statTimerFires);
    DictSetNumber(status, "Bursts", iv->statBursts);
    DictSetNumber(status, "CompletedByInterrupt", iv->statCompletedByInterrupt);
    DictSetNumber(status, "CompletedByTimer", iv->statCompletedByTimer);
    DictSetNumber(status, "PeakInflight", iv->statPeakInflight);
    DictSetNumber(status, "PeakBurst", iv->statPeakBurst);
    DictSetNumber(status, "DoorbellBusy", iv->statDoorbellBusy);
    static const char * const kLatencyKeys[4][3] = {
        { "Latency4KCount",   "Latency4KAvgUS",   "Latency4KMaxUS"   },
        { "Latency64KCount",  "Latency64KAvgUS",  "Latency64KMaxUS"  },
        { "Latency256KCount", "Latency256KAvgUS", "Latency256KMaxUS" },
        { "Latency512KCount", "Latency512KAvgUS", "Latency512KMaxUS" },
    };
    for (int bucket = 0; bucket < 4; bucket++) {
        const uint64_t count = iv->latencyCount[bucket];
        const uint64_t perMS = iv->ticksPerMillisecond ? iv->ticksPerMillisecond : 1;
        DictSetNumber(status, kLatencyKeys[bucket][0], count);
        DictSetNumber(status, kLatencyKeys[bucket][1], count ? (iv->latencyTicks[bucket] / count) * 1000 / perMS : 0);
        DictSetNumber(status, kLatencyKeys[bucket][2], iv->latencyMaxTicks[bucket] * 1000 / perMS);
    }
    DictSetNumber(status, "Inflight", iv->inflight);
    DictSetNumber(status, "Pending", iv->pendingCount);
    DictSetNumber(status, "Reads", iv->statReads);
    DictSetNumber(status, "ReadBytes", iv->statReadBytes);
    DictSetNumber(status, "Errors", iv->statErrors);
    DictSetNumber(status, "RejectedWrites", iv->statRejectedWrites);
    DictSetNumber(status, "LastSRBResponse", iv->lastSRBResponse);
    DictSetNumber(status, "LastSCSIStatus", iv->lastSCSIStatus);
    DictSetNumber(status, "NextTransactionID", iv->nextTransactionID);
    if (iv->pciDevice != nullptr && iv->pciOpen) {
        DictSetNumber(status, "OutCause", Reg32(iv, kDroboRegOutgoingDoorbellCause));
        DictSetNumber(status, "InCause", Reg32(iv, kDroboRegIncomingDoorbellCause));
        DictSetNumber(status, "InMask", Reg32(iv, kDroboRegIncomingDoorbellMask));
    }
    uint32_t present = 0;
    for (uint32_t lun = 0; lun < 32; lun++) {
        if (iv->luns[lun].present) {
            present++;
        }
    }
    DictSetNumber(status, "LUNsPresent", present);

    OSDictionary * wrapper = OSDictionary::withCapacity(1);
    if (wrapper != nullptr) {
        wrapper->setObject("DroboStatus", status);
        service->SetProperties(wrapper);
        wrapper->release();
    }
    status->release();
}

// Doorbell bits, as published by the device's own interrupt tables (verified at bring-up).
static const uint32_t kInBitSCSIRequest   = 0x00020000;   // In[0]
static const uint32_t kInBitTMRequest     = 0x08000000;   // In[4]
static const uint32_t kOutBitSCSIResponse = 0x00000002;   // Out[0]
static const uint32_t kOutBitTMResponse   = 0x00000800;   // Out[1]
static const uint32_t kOutBitSysResponse  = 0x00000400;   // Out[2]
static const uint32_t kOutBitAdapterReady = 0x00000001;   // Out[4]
static const uint32_t kOutBitSummary      = 0x00000004;   // Out[5]
static const uint32_t kDroboRegEndpointInterrupt  = 0x20B08;      // outbound table header
static const uint32_t kDroboEndpointInterruptBits = 0x80010000;

// MARK: Bring-up

// Checks that the interrupt-table entries we rely on say what we hard-coded above.
static bool
VerifyInterruptTables(DroboSCSIController_IVars * iv, uint32_t intIn, uint32_t intOut)
{
    const uint32_t in0  = intIn + kDroboInterruptTableHeaderSize;                      // In[0]
    const uint32_t out0 = intOut + kDroboInterruptTableHeaderSize;                     // Out[0]
    const uint32_t out4 = out0 + 4 * (uint32_t) sizeof(DroboInterruptDef);             // Out[4]
    const uint32_t out5 = out0 + 5 * (uint32_t) sizeof(DroboInterruptDef);             // Out[5]

    // trigger group is at +0x04 (offset, size, value, op); state at +0x14; clear at +0x44.
    bool ok = true;
    ok = ok && Port32(iv, in0 + 0x04) == kDroboRegIncomingDoorbellCause;
    ok = ok && Port32(iv, in0 + 0x0C) == kInBitSCSIRequest;
    ok = ok && Port32(iv, in0 + 0x10) == kDroboRegOpSet;
    ok = ok && Port32(iv, out0 + 0x14) == kDroboRegOutgoingDoorbellCause;
    ok = ok && Port32(iv, out0 + 0x1C) == kOutBitSCSIResponse;
    ok = ok && Port32(iv, out0 + 0x44) == kDroboRegOutgoingDoorbellCause;
    ok = ok && Port32(iv, out0 + 0x4C) == ~kOutBitSCSIResponse;
    ok = ok && Port32(iv, out0 + 0x50) == kDroboRegOpSet;
    ok = ok && Port32(iv, out4 + 0x1C) == kOutBitAdapterReady;
    ok = ok && Port32(iv, out5 + 0x1C) == kOutBitSummary;
    ok = ok && Port32(iv, out5 + 0x4C) == ~kOutBitSummary;
    return ok;
}

// One HOST_BAR_READY handshake. Returns true when the firmware cleared the bit.
static bool
HostBarReady(DroboSCSIController_IVars * iv, uint32_t maxPolls)
{
    uint32_t cause = Reg32(iv, kDroboRegIncomingDoorbellCause);
    if (cause == 0xFFFFFFFF) {
        return false;
    }
    if ((cause & kDroboHostBarReadyBit) == 0) {
        RegWrite32(iv, kDroboRegIncomingDoorbellCause, cause | kDroboHostBarReadyBit);
    }
    for (uint32_t poll = 0; poll < maxPolls && !iv->stopping; poll++) {
        IOSleep(500);
        cause = Reg32(iv, kDroboRegIncomingDoorbellCause);
        if (cause == 0xFFFFFFFF) {
            return false;
        }
        if ((cause & kDroboHostBarReadyBit) == 0) {
            return true;
        }
    }
    return false;
}

static bool
SignatureValid(DroboSCSIController_IVars * iv)
{
    uint32_t words[4];
    for (int i = 0; i < 4; i++) {
        words[i] = Port32(iv, 4 * i);
    }
    char signature[kDroboPortSignatureLength + 1] = {};
    memcpy(signature, words, kDroboPortSignatureLength);
    return strncmp(signature, kDroboPortSignature, kDroboPortSignatureLength) == 0;
}

static bool
BringUp(IOService * service, DroboSCSIController_IVars * iv)
{
    IOPCIDevice * pci = iv->pciDevice;
    uint8_t  regType = 0, portType = 0;
    uint64_t regSize = 0;

    if (pci->GetBARInfo(kDroboRegisterBAR, &iv->regIndex, &regSize, &regType) != kIOReturnSuccess ||
        pci->GetBARInfo(kDroboPortBAR, &iv->portIndex, &iv->portSize, &portType) != kIOReturnSuccess ||
        regSize < 0x21880 || iv->portSize < 0x1000) {
        SetStage(iv, "bars-unexpected");
        return false;
    }

    // Map both BARs for direct access; fall back to the accessors if that is not possible.
    iv->regBase  = MapBAR(service, pci, iv->regIndex, regSize, &iv->regMap);
    iv->portBase = MapBAR(service, pci, iv->portIndex, iv->portSize, &iv->portMap);
    if (iv->regBase == nullptr || iv->portBase == nullptr) {
        iv->regBase = nullptr;
        iv->portBase = nullptr;
        DLog("direct BAR mapping unavailable, using IOPCIDevice accessors");
    }

    // Memory space + bus mastering. The device must be able to DMA requests and data now;
    // the IOMMU confines it to the buffers that are mapped for it.
    uint16_t command = 0;
    pci->ConfigurationRead16(kCfgCommand, &command);
    pci->ConfigurationWrite16(kCfgCommand, command | 0x6);

    // Request buffer: one page, bus address below 4 GiB.
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, 0x4000, 0x4000, &iv->requestBuffer);
    if (ret != kIOReturnSuccess) {
        SetStage(iv, "request-buffer-alloc-failed");
        return false;
    }
    iv->requestBuffer->SetLength(0x4000);
    IOAddressSegment range = {};
    iv->requestBuffer->GetAddressRange(&range);
    iv->requestVA = (uint8_t *) range.address;

    IODMACommandSpecification spec = {};
    spec.options = kIODMACommandSpecificationNoOptions;
    spec.maxAddressBits = kDroboDMAAddressBits;
    ret = IODMACommand::Create(pci, kIODMACommandCreateNoOptions, &spec, &iv->requestDMA);
    if (ret != kIOReturnSuccess) {
        SetStage(iv, "dma-create-failed");
        return false;
    }
    uint64_t flags = 0;
    uint32_t segmentCount = 32;
    IOAddressSegment segments[32] = {};
    ret = iv->requestDMA->PrepareForDMA(kIODMACommandPrepareForDMANoOptions, iv->requestBuffer, 0, 0x4000,
                                        &flags, &segmentCount, segments);
    if (ret != kIOReturnSuccess || segmentCount < 1 || segments[0].length < 0x1000 ||
        (segments[0].address >> 32) != 0 || iv->requestVA == nullptr) {
        DLog("request DMA prepare failed 0x%08x segs %u addr 0x%llx len 0x%llx",
             ret, segmentCount, segments[0].address, segments[0].length);
        SetStage(iv, "dma-prepare-failed");
        return false;
    }
    iv->requestBusAddress = segments[0].address;

    // Wait for the firmware: handshake acknowledged, DroboPort published, adapter ready.
    SetStage(iv, "waiting-for-firmware");
    PublishStatus(service, iv);
    bool up = false;
    for (uint32_t attempt = 0; attempt < 60 && !iv->stopping; attempt++) {      // ~5 minutes
        bool acknowledged = HostBarReady(iv, 10);
        if (Reg32(iv, kDroboRegIncomingDoorbellCause) == 0xFFFFFFFF) {
            SetStage(iv, "device-removed");
            return false;
        }
        if (acknowledged && SignatureValid(iv) &&
            (Reg32(iv, kDroboRegOutgoingDoorbellCause) & kOutBitAdapterReady) != 0) {
            up = true;
            break;
        }
    }
    if (!up) {
        SetStage(iv, iv->stopping ? "stopped" : "firmware-not-ready");
        return false;
    }

    // Parse DroboPort.
    iv->lunTableOffset      = Port32(iv, kDroboPortLUNTableOffset);
    iv->capabilitiesOffset  = Port32(iv, kDroboPortCapabilitiesOffset);
    iv->requestListOffset   = Port32(iv, kDroboPortSCSIRequestOffset);
    iv->responseListOffset  = Port32(iv, kDroboPortSCSIResponseOffset);
    const uint32_t intIn    = Port32(iv, kDroboPortInterruptInOffset);
    const uint32_t intOut   = Port32(iv, kDroboPortInterruptOutOffset);
    const uint32_t serial   = Port32(iv, kDroboPortSerialNumberOffset);

    const uint64_t limit = iv->portSize - 0x400;
    if (iv->lunTableOffset > limit || iv->capabilitiesOffset > limit || iv->requestListOffset > limit ||
        iv->responseListOffset > limit || intIn > limit || intOut > limit) {
        SetStage(iv, "droboport-offsets-invalid");
        return false;
    }

    iv->interfaceVersion = Port32(iv, iv->capabilitiesOffset + 0x00);
    iv->maxTransferSize  = Port32(iv, iv->capabilitiesOffset + 0x08);
    iv->lunCount         = Port32(iv, iv->capabilitiesOffset + 0x10);
    if (iv->lunCount > 32) {
        iv->lunCount = 32;
    }
    // This driver only implements the wide (interface >= 4) response entries.
    if (iv->interfaceVersion < 4 || iv->maxTransferSize < 0x1000 ||
        Port32(iv, iv->requestListOffset) < 1) {
        SetStage(iv, "unsupported-interface");
        return false;
    }
    if (iv->maxTransferSize > kDroboDMAMaxSegmentSize) {
        iv->maxTransferSize = (uint32_t) kDroboDMAMaxSegmentSize;
    }
    if (!VerifyInterruptTables(iv, intIn, intOut)) {
        SetStage(iv, "interrupt-table-mismatch");
        return false;
    }

    if (serial != 0xFFFFFFFF && serial <= limit) {
        uint32_t words[8];
        for (int i = 0; i < 8; i++) {
            words[i] = Port32(iv, serial + 4 * i);
        }
        memcpy(iv->serial, words, 32);
        iv->serial[32] = 0;
    }

    // Announce the host, as the original driver does.
    PortWrite32(iv, iv->capabilitiesOffset + 0x24, 1);

    for (uint32_t lun = 0; lun < iv->lunCount; lun++) {
        const uint32_t entry = iv->lunTableOffset + lun * (uint32_t) sizeof(DroboLUNEntry);
        const uint32_t present   = Port32(iv, entry + 0);
        const uint32_t blockSize = Port32(iv, entry + 4);
        const uint64_t blocks    = (uint64_t) Port32(iv, entry + 8) | ((uint64_t) Port32(iv, entry + 12) << 32);
        // Only 512-byte LUNs are understood; anything else is not published.
        iv->luns[lun].present    = (present != 0 && blockSize == 512 && blocks != 0);
        iv->luns[lun].blockSize  = blockSize;
        iv->luns[lun].blockCount = blocks;
        if (present != 0) {
            DLog("LUN %u: block size %u, %llu blocks", lun, blockSize, blocks);
        }
    }

    // Start from a clean outbound state (the original driver's ClearAndEnableInterrupts, minus
    // the enable: completions are polled in this stage).
    RegWrite32(iv, kDroboRegOutgoingDoorbellCause, ~kOutBitSummary);
    RegWrite32(iv, kDroboRegOutgoingDoorbellCause, ~kOutBitSCSIResponse);
    RegWrite32(iv, kDroboRegOutgoingDoorbellCause, ~kOutBitTMResponse);
    RegWrite32(iv, kDroboRegOutgoingDoorbellCause, ~kOutBitSysResponse);

    // The original driver repeats the handshake at connect time.
    if (!HostBarReady(iv, 120) || !SignatureValid(iv)) {
        SetStage(iv, "second-handshake-failed");
        return false;
    }

    // Passthrough channel, used only for read-only health queries. Enabled when its doorbell
    // entries in the device's tables are what we expect.
    iv->tmRequestListOffset  = Port32(iv, kDroboPortTMRequestOffset);
    iv->tmResponseListOffset = Port32(iv, kDroboPortTMResponseOffset);
    {
        const uint32_t in4  = intIn + kDroboInterruptTableHeaderSize + 4 * (uint32_t) sizeof(DroboInterruptDef);
        const uint32_t out1 = intOut + kDroboInterruptTableHeaderSize + 1 * (uint32_t) sizeof(DroboInterruptDef);
        iv->healthAvailable =
            iv->tmRequestListOffset <= limit && iv->tmResponseListOffset <= limit &&
            Port32(iv, iv->tmRequestListOffset) >= 1 &&
            Port32(iv, in4 + 0x04) == kDroboRegIncomingDoorbellCause && Port32(iv, in4 + 0x0C) == kInBitTMRequest &&
            Port32(iv, in4 + 0x10) == kDroboRegOpSet &&
            Port32(iv, out1 + 0x14) == kDroboRegOutgoingDoorbellCause && Port32(iv, out1 + 0x1C) == kOutBitTMResponse &&
            Port32(iv, out1 + 0x4C) == ~kOutBitTMResponse && Port32(iv, out1 + 0x50) == kDroboRegOpSet;
        iv->healthSlotCount = 8;
    }

    // Requests per doorbell: the original driver stops one short of the window size.
    const uint32_t window = Port32(iv, iv->requestListOffset);
    iv->burstMax = (window > 1 && window <= 64) ? window - 1 : 1;
    uint32_t outstanding = Port32(iv, iv->capabilitiesOffset + 0x0C);
    iv->maxInflight = (outstanding == 0 || outstanding > kDroboSlotCount) ? kDroboSlotCount : outstanding;

    // Device-side interrupt enable, straight from the outbound table: summary bit (Out[5])
    // in the outbound mask, then the endpoint interrupt. Only done when the table says what we
    // expect and an MSI source exists; otherwise completions are found by the timer.
    const uint32_t out5 = intOut + kDroboInterruptTableHeaderSize + 5 * (uint32_t) sizeof(DroboInterruptDef);
    const bool tableOK =
        Port32(iv, out5 + 0x24) == kDroboRegOutgoingDoorbellMask && Port32(iv, out5 + 0x2C) == kOutBitSummary &&
        Port32(iv, out5 + 0x30) == kDroboRegOpOr &&
        Port32(iv, intOut + 0x04) == kDroboRegEndpointInterrupt && Port32(iv, intOut + 0x0C) == kDroboEndpointInterruptBits &&
        Port32(iv, intOut + 0x10) == kDroboRegOpOr;
    if (tableOK && iv->interruptSource != nullptr) {
        RegWrite32(iv, kDroboRegOutgoingDoorbellMask, Reg32(iv, kDroboRegOutgoingDoorbellMask) | kOutBitSummary);
        RegWrite32(iv, kDroboRegEndpointInterrupt, Reg32(iv, kDroboRegEndpointInterrupt) | kDroboEndpointInterruptBits);
        iv->deviceInterruptsEnabled = true;
    }

    iv->ready = true;
    SetStage(iv, "ready");
    return true;
}

// MARK: SCSI helpers

static void
InitResponse(SCSIUserParallelResponse * response, const SCSIUserParallelTask * task)
{
    bzero(response, sizeof(*response));
    response->version                   = kScsiUserParallelTaskResponseCurrentVersion1;
    response->fTargetID                 = task->fTargetID;
    response->fControllerTaskIdentifier = task->fControllerTaskIdentifier;
    response->fCompletionStatus         = kSCSITaskStatus_GOOD;
    response->fServiceResponse          = kSCSIServiceResponse_TASK_COMPLETE;
}

static void
SetSense(SCSIUserParallelResponse * response, uint8_t key, uint8_t asc, uint8_t ascq)
{
    response->fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
    response->fBytesTransferred = 0;
    response->fSenseLength      = 18;
    bzero(response->fSenseBuffer, 18);
    response->fSenseBuffer[0]  = 0x70;      // fixed format, current
    response->fSenseBuffer[2]  = key;
    response->fSenseBuffer[7]  = 10;        // additional length
    response->fSenseBuffer[12] = asc;
    response->fSenseBuffer[13] = ascq;
}

enum : uint8_t {
    kSenseIllegalRequest = 0x05,
    kSenseDataProtect    = 0x07,
    kSenseHardwareError  = 0x04,
    kSenseNotReady       = 0x02,
};

static inline uint16_t BE16(const uint8_t * p) { return (uint16_t) ((p[0] << 8) | p[1]); }
static inline uint32_t BE32(const uint8_t * p) { return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) | ((uint32_t) p[2] << 8) | p[3]; }
static inline uint64_t BE64(const uint8_t * p) { return ((uint64_t) BE32(p) << 32) | BE32(p + 4); }
static inline void PutBE32(uint8_t * p, uint32_t v) { p[0] = (uint8_t) (v >> 24); p[1] = (uint8_t) (v >> 16); p[2] = (uint8_t) (v >> 8); p[3] = (uint8_t) v; }
static inline void PutBE64(uint8_t * p, uint64_t v) { PutBE32(p, (uint32_t) (v >> 32)); PutBE32(p + 4, (uint32_t) v); }

static void
PadCopy(uint8_t * destination, const char * source, size_t width)
{
    memset(destination, ' ', width);
    size_t length = strlen(source);
    memcpy(destination, source, length < width ? length : width);
}

// MARK: Start / Stop

kern_return_t
IMPL(DroboSCSIController, Start)
{
    DLog("Start");

    ivars->pciDevice = OSDynamicCast(IOPCIDevice, provider);
    if (ivars->pciDevice == nullptr) {
        DLog("provider is not an IOPCIDevice");
        return kIOReturnNoDevice;
    }
    ivars->pciDevice->retain();

    kern_return_t ret = ivars->pciDevice->Open(this, 0);
    if (ret != kIOReturnSuccess) {
        DLog("IOPCIDevice::Open failed 0x%08x", ret);
        return ret;
    }
    ivars->pciOpen = true;

    LogPCIConfiguration(ivars->pciDevice);

    // SCSIControllerDriverKit requires the dext to provide these two named queues. Without
    // "AuxiliaryQueue", UserCreateTargetForID never returns (v0.7.0 hung there).
    // v0.8.0 treated a failure here as fatal and exited at once; now each result code is
    // recorded and published instead, and registration is retried after super Start.
    ivars->queueResult[0] = IODispatchQueue::Create("AuxiliaryQueue", 0, 0, &ivars->auxiliaryQueue);
    ivars->queueResult[1] = IODispatchQueue::Create("InterruptQueue", 0, 0, &ivars->interruptQueue);
    // The queues are only registered after super Start: v0.7.0 showed super Start succeeds
    // without them, and the target is not created until bring-up finishes much later.

    ret = Start(provider, SUPERDISPATCH);
    ivars->superStartResult = (uint32_t) ret;
    if (ret != kIOReturnSuccess) {
        DLog("super Start failed 0x%08x", ret);
        ivars->pciDevice->Close(this, 0);
        ivars->pciOpen = false;
        return ret;
    }

    // Bring-up can take minutes (firmware boot), so it runs on the serial I/O queue. SCSI
    // tasks are handled on the same queue, so they naturally wait behind it.
    CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->defaultQueue);
    ivars->queueResult[2] = ivars->auxiliaryQueue ? SetDispatchQueue("AuxiliaryQueue", ivars->auxiliaryQueue) : kIOReturnNoMemory;
    ivars->queueResult[3] = ivars->interruptQueue ? SetDispatchQueue("InterruptQueue", ivars->interruptQueue) : kIOReturnNoMemory;

    // Global transfer limit: one Drobo request, never split.
    OSDictionary * limits = OSDictionary::withCapacity(2);
    if (limits != nullptr) {
        DictSetNumber(limits, "IOMaximumByteCountRead", kDroboDMAMaxSegmentSize);
        DictSetNumber(limits, "IOMaximumByteCountWrite", kDroboDMAMaxSegmentSize);
        SetProperties(limits);
        limits->release();
    }

    IODispatchQueue::Create("DroboTarget", 0, 0, &ivars->targetQueue);
    ret = IODispatchQueue::Create("DroboIO", 0, 0, &ivars->probeQueue);

    struct mach_timebase_info timebase = {};
    mach_timebase_info(&timebase);
    ivars->ticksPerMillisecond = (timebase.numer != 0) ? (1000000ull * timebase.denom / timebase.numer) : 24000;

    if (ret == kIOReturnSuccess) {
        // Timer: completion poll when interrupts are not available, timeout check otherwise.
        if (IOTimerDispatchSource::Create(ivars->probeQueue, &ivars->timerSource) == kIOReturnSuccess &&
            CreateActionHandleTimer(0, &ivars->timerAction) == kIOReturnSuccess) {
            ivars->timerSource->SetHandler(ivars->timerAction);
            ivars->timerSource->SetEnable(true);
        } else {
            OSSafeReleaseNULL(ivars->timerSource);
        }

        // Health poll: first fire after a second, then every five.
        if (IOTimerDispatchSource::Create(ivars->probeQueue, &ivars->healthTimer) == kIOReturnSuccess &&
            CreateActionHandleHealthTimer(0, &ivars->healthAction) == kIOReturnSuccess) {
            ivars->healthTimer->SetHandler(ivars->healthAction);
            ivars->healthTimer->SetEnable(true);
            const uint64_t first = 3000 * ivars->ticksPerMillisecond;
            ivars->healthTimer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + first, first / 10);
        } else {
            OSSafeReleaseNULL(ivars->healthTimer);
        }

        // MSI: one vector, delivered on the I/O queue.
        kern_return_t msi = ivars->pciDevice->ConfigureInterrupts(kIOInterruptTypePCIMessaged, 1, 1, 0);
        uint32_t index = 0xFFFFFFFF;
        if (msi == kIOReturnSuccess) {
            for (uint32_t i = 0; i < 8; i++) {
                uint64_t type = 0;
                if (IOInterruptDispatchSource::GetInterruptType(ivars->pciDevice, i, &type) != kIOReturnSuccess) {
                    break;
                }
                if ((type & kIOInterruptTypePCIMessaged) != 0) {
                    index = i;
                    break;
                }
            }
            if (index == 0xFFFFFFFF) {
                msi = kIOReturnNotFound;
            }
        }
        if (msi == kIOReturnSuccess) {
            msi = IOInterruptDispatchSource::Create(ivars->pciDevice, index, ivars->probeQueue, &ivars->interruptSource);
        }
        if (msi == kIOReturnSuccess) {
            msi = CreateActionHandleInterrupt(0, &ivars->interruptAction);
        }
        if (msi == kIOReturnSuccess) {
            msi = ivars->interruptSource->SetHandler(ivars->interruptAction);
        }
        if (msi == kIOReturnSuccess) {
            msi = ivars->interruptSource->SetEnable(true);
        }
        if (msi != kIOReturnSuccess) {
            OSSafeReleaseNULL(ivars->interruptSource);      // completions fall back to the timer
        }
        ivars->msiIndex = index;
        ivars->interruptSetupResult = (uint32_t) msi;
    }
    if (ret == kIOReturnSuccess) {
        ivars->probeQueue->DispatchAsync(^{
            bool up = BringUp(this, ivars);
            PublishStatus(this, ivars);
            ivars->probeDone = true;
            if (up && !ivars->stopping && ivars->targetQueue != nullptr) {
                // Target creation is synchronous and makes the family send INQUIRY etc. Those
                // tasks are served on the I/O queue, so the call must come from another queue
                // or it deadlocks against itself (v0.6.0 did exactly that).
                ivars->targetQueue->DispatchAsync(^{
                    OSDictionary * target = OSDictionary::withCapacity(1);
                    ivars->targetCallInFlight = true;
                    kern_return_t created = UserCreateTargetForID(0, target);
                    ivars->targetCallInFlight = false;
                    DLog("UserCreateTargetForID(0) -> 0x%08x", created);
                    OSSafeReleaseNULL(target);
                    ivars->createTargetResult = (uint32_t) created;
                    ivars->targetCreated = true;
                    PublishStatus(this, ivars);
                });
            }
        });
    }

    DLog("Start complete");
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, Stop)
{
    DLog("Stop");
    if (ivars == nullptr) {
        return Stop(provider, SUPERDISPATCH);
    }

    ivars->stopping = true;

    // Quiesce on the I/O queue: mask the device's interrupt, fail whatever is outstanding.
    // Skipped while bring-up is still running there; it checks `stopping` and returns soon.
    if (ivars->probeQueue != nullptr) {
        for (int i = 0; i < 60 && !ivars->probeDone; i++) {
            IOSleep(100);
        }
        if (ivars->probeDone) {
            ivars->probeQueue->DispatchSync(^{
                if (ivars->deviceInterruptsEnabled && ivars->pciOpen) {
                    RegWrite32(ivars, kDroboRegEndpointInterrupt, Reg32(ivars, kDroboRegEndpointInterrupt) & ~kDroboEndpointInterruptBits);
                    RegWrite32(ivars, kDroboRegOutgoingDoorbellMask, Reg32(ivars, kDroboRegOutgoingDoorbellMask) & ~kOutBitSummary);
                    ivars->deviceInterruptsEnabled = false;
                }
                FailAllSlots("stopped");
            });
        }
    }
    ivars->regBase = nullptr;       // nothing touches MMIO directly from here on
    ivars->portBase = nullptr;
    if (ivars->requestDMA != nullptr) {
        ivars->requestDMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
    }
    if (ivars->pciDevice != nullptr && ivars->pciOpen) {
        ivars->pciDevice->Close(this, 0);
        ivars->pciOpen = false;
    }

    // A dext cannot finish terminating while its dispatch sources and queues are alive:
    // cancel them all and complete Stop from the last cancel handler. A queue whose block is
    // still inside a kernel call is skipped, because its cancel handler would never run.
    __block uint32_t remaining = 1;         // +1 held by this function until all are issued
    provider->retain();
    void (^finished)(void) = ^{
        if (__sync_sub_and_fetch(&remaining, 1) == 0) {
            Stop(provider, SUPERDISPATCH);
            provider->release();
        }
    };
    if (ivars->interruptSource != nullptr)                           { __sync_add_and_fetch(&remaining, 1); ivars->interruptSource->Cancel(finished); }
    if (ivars->timerSource != nullptr)                               { __sync_add_and_fetch(&remaining, 1); ivars->timerSource->Cancel(finished); }
    if (ivars->healthTimer != nullptr)                               { __sync_add_and_fetch(&remaining, 1); ivars->healthTimer->Cancel(finished); }
    if (ivars->probeQueue != nullptr)                                { __sync_add_and_fetch(&remaining, 1); ivars->probeQueue->Cancel(finished); }
    if (ivars->targetQueue != nullptr && !ivars->targetCallInFlight) { __sync_add_and_fetch(&remaining, 1); ivars->targetQueue->Cancel(finished); }
    if (ivars->auxiliaryQueue != nullptr)                            { __sync_add_and_fetch(&remaining, 1); ivars->auxiliaryQueue->Cancel(finished); }
    if (ivars->interruptQueue != nullptr)                            { __sync_add_and_fetch(&remaining, 1); ivars->interruptQueue->Cancel(finished); }
    finished();
    return kIOReturnSuccess;
}

// MARK: Controller bring-up

kern_return_t
IMPL(DroboSCSIController, UserInitializeController)
{
    // The framework requires the I/O constraints to be reported before this method returns.
    // All seven keys are mandatory (the SDK header says the system panics without them).
    // v0.6-v0.11 never reported them; the family then accepted TEST UNIT READY (no data) but
    // never delivered a data-carrying command such as INQUIRY.
    OSDictionary * constraints = OSDictionary::withCapacity(8);
    if (constraints == nullptr) {
        return kIOReturnNoMemory;
    }
    DictSetNumber(constraints, kIOMaximumSegmentCountReadKey, 256);
    DictSetNumber(constraints, kIOMaximumSegmentCountWriteKey, 256);
    DictSetNumber(constraints, kIOMaximumSegmentByteCountReadKey, kDroboDMAMaxSegmentSize);
    DictSetNumber(constraints, kIOMaximumSegmentByteCountWriteKey, kDroboDMAMaxSegmentSize);
    DictSetNumber(constraints, kIOMinimumSegmentAlignmentByteCountKey, 4);
    DictSetNumber(constraints, kIOMaximumSegmentAddressableBitCountKey, kDroboDMAAddressBits);
    DictSetNumber(constraints, kIOMinimumHBADataAlignmentMaskKey, 0x00000000FFFFFFFCull);
    ivars->constraintsResult = (uint32_t) UserReportHBAConstraints(constraints);
    constraints->release();
    DLog("UserReportHBAConstraints -> 0x%08x", ivars->constraintsResult);
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserStartController)
{
    // Next stage: enable MSI, SetDriverReady, wait for adapter ready, create target 0.
    DLog("UserStartController (stub)");
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserGetDMASpecification)
{
    // 32-bit little-endian bus addresses, as the original driver.
    *maxTransferSize = kDroboDMAMaxSegmentSize;     // 512 KiB: one request, never split
    *alignment       = 4;
    *numAddressBits  = kDroboDMAAddressBits;
    // Host64, not Little32: the family hands us the buffer address as a 64-bit value
    // (fBufferIOVMAddr), so it reads 64-bit segments. With a 32-bit output function the
    // first data-carrying command (INQUIRY) never reached the driver. Addresses are still
    // limited to 32 bits by numAddressBits.
    *segmentType     = kDMAOutputSegmentHost64;
    return kIOReturnSuccess;
}

// MARK: Controller characteristics

kern_return_t
IMPL(DroboSCSIController, UserReportInitiatorIdentifier)
{
    *id = 1;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserReportHighestSupportedDeviceID)
{
    *id = 0;    // the Drobo is a single target, ID 0
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserReportHBAHighestLogicalUnitNumber)
{
    *value = 31;    // the kext's default before MaxLUNs is read from the device
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserReportMaximumTaskCount)
{
    *count = kDroboSlotCount;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserDoesHBASupportSCSIParallelFeature)
{
    *result = false;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserDoesHBAPerformDeviceManagement)
{
    *result = true;     // we create target 0 ourselves once the adapter reports ready
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserDoesHBAPerformAutoSense)
{
    *result = true;     // sense data is returned in the task response
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserDoesHBASupportMultiPathing)
{
    *result = false;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserInitializeTargetForID)
{
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserMapHBAData)
{
    *uniqueTaskID = __sync_add_and_fetch(&ivars->nextTaskID, 1);     // starts at 1: task ID 0 is reserved
    return kIOReturnSuccess;
}


// MARK: I/O

// Copies driver-generated data into the task's data-in buffer.
uint64_t
DroboSCSIController::CopyToTask(const SCSIUserParallelTask * task, const void * bytes, uint64_t length)
{
    if (length > task->fRequestedTransferCount) {
        length = task->fRequestedTransferCount;
    }
    if (length == 0) {
        return 0;
    }
    IOBufferMemoryDescriptor * buffer = nullptr;
    kern_return_t ret = UserGetDataBuffer((SCSIDeviceIdentifier) task->fTargetID, task->fControllerTaskIdentifier, &buffer);
    if (ret != kIOReturnSuccess || buffer == nullptr) {
        DLog("UserGetDataBuffer failed 0x%08x", ret);
        return 0;
    }
    uint64_t copied = 0;
    IOMemoryMap * map = nullptr;
    ret = buffer->CreateMapping(0, 0, 0, 0, 0, &map);
    if (ret == kIOReturnSuccess && map != nullptr) {
        if (length > map->GetLength()) {
            length = map->GetLength();
        }
        memcpy((void *) map->GetAddress(), bytes, length);
        copied = length;
    } else {
        DLog("data buffer CreateMapping failed 0x%08x", ret);
    }
    OSSafeReleaseNULL(map);
    OSSafeReleaseNULL(buffer);
    return copied;
}

// MARK: Concurrent read path
//
// Everything below runs on the serial I/O queue ("DroboIO"): task intake, burst submission,
// the MSI handler and the timer. That one queue is the lock.

void
DroboSCSIController::ArmTimer()
{
    DroboSCSIController_IVars * iv = ivars;
    if (iv->timerSource == nullptr || iv->timerArmed || iv->stopping) {
        return;
    }
    // With working interrupts the timer is only a safety net and a timeout check; without
    // them it is the completion poll.
    const uint64_t intervalMS = (iv->deviceInterruptsEnabled && iv->statInterrupts != 0) ? 20 : 1;
    const uint64_t ticks = intervalMS * iv->ticksPerMillisecond;
    if (iv->timerSource->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + ticks, ticks / 4) == kIOReturnSuccess) {
        iv->timerArmed = true;
    }
}

void
DroboSCSIController::CompleteSlot(uint32_t index, uint32_t taskStatus, uint32_t serviceResponse,
                                  uint64_t bytes, uint8_t senseKey, uint8_t asc)
{
    DroboSCSIController_IVars * iv = ivars;
    DroboSlot * slot = &iv->slots[index];
    if (!slot->inUse) {
        return;
    }
    SCSIUserParallelResponse response;
    bzero(&response, sizeof(response));
    response.version                   = kScsiUserParallelTaskResponseCurrentVersion1;
    response.fTargetID                 = slot->targetID;
    response.fControllerTaskIdentifier = slot->taskID;
    response.fCompletionStatus         = (SCSITaskStatus) taskStatus;
    response.fServiceResponse          = (SCSIServiceResponse) serviceResponse;
    response.fBytesTransferred         = bytes;
    if (senseKey != 0) {
        SetSense(&response, senseKey, asc, 0x00);
    }

    OSAction * completion = slot->completion;
    if (slot->submitted && iv->inflight != 0) {
        iv->inflight--;
    }
    slot->inUse = false;
    slot->submitted = false;
    slot->completion = nullptr;

    if (completion != nullptr) {
        ParallelTaskCompletion(completion, response);
        completion->release();
    }
    iv->statCompleted++;
}

void
DroboSCSIController::FailAllSlots(const char * stage)
{
    DroboSCSIController_IVars * iv = ivars;
    iv->dead = true;
    iv->pendingCount = 0;
    SetStage(iv, stage);
    for (uint32_t i = 0; i < kDroboSlotCount; i++) {
        if (iv->slots[i].inUse) {
            iv->statErrors++;
            CompleteSlot(i, kSCSITaskStatus_No_Status, kSCSIServiceResponse_SERVICE_DELIVERY_OR_TARGET_FAILURE, 0, 0, 0);
        }
    }
    iv->inflight = 0;
    PublishStatus(this, iv);
}

// Drains every response burst that is ready. Returns the number of tasks completed.
uint32_t
DroboSCSIController::ProcessCompletions()
{
    DroboSCSIController_IVars * iv = ivars;
    uint32_t completed = 0;

    if (!iv->ready || iv->dead) {
        return 0;
    }
    for (uint32_t round = 0; round < 64; round++) {
        const uint32_t out = Reg32(iv, kDroboRegOutgoingDoorbellCause);
        if (out == 0xFFFFFFFF) {
            FailAllSlots("device-removed");
            return completed;
        }
        if ((out & kOutBitSummary) != 0) {
            RegWrite32(iv, kDroboRegOutgoingDoorbellCause, ~kOutBitSummary);
        }
        if ((out & kOutBitTMResponse) != 0) {
            HealthResponse();
        }
        if ((out & kOutBitSCSIResponse) == 0) {
            break;
        }

        uint32_t count = Port32(iv, iv->responseListOffset + kDroboResponseListCountOffset);
        if (count == 0xFFFFFFFF) {
            FailAllSlots("device-removed");
            return completed;
        }
        if (count > 8) {
            count = 8;      // the response list holds eight 32-byte entries
        }
        for (uint32_t i = 0; i < count; i++) {
            const uint32_t base = iv->responseListOffset + kDroboResponseListEntriesOffset +
                                  i * (uint32_t) sizeof(DroboResponseEntryV4);
            const uint32_t index         = Port32(iv, base + 0x00);
            const uint32_t transactionID = Port32(iv, base + 0x04);
            const uint64_t transferred   = (uint64_t) Port32(iv, base + 0x08) | ((uint64_t) Port32(iv, base + 0x0C) << 32);
            const uint32_t srbResponse   = Port32(iv, base + 0x14);
            const uint32_t scsiStatus    = Port32(iv, base + 0x18);

            if (index >= kDroboSlotCount || !iv->slots[index].inUse || !iv->slots[index].submitted ||
                iv->slots[index].transactionID != transactionID) {
                // Not one of ours (or one we already gave up on): never complete the wrong task.
                DLog("stale response: slot %u tid %u", index, transactionID);
                iv->statErrors++;
                continue;
            }
            iv->lastSRBResponse = srbResponse;
            iv->lastSCSIStatus  = scsiStatus;
            const uint64_t length = iv->slots[index].length;
            if ((srbResponse != kDroboSRBResponseSuccess && srbResponse != kDroboSRBResponseShort) || scsiStatus != 0) {
                DLog("read failed: slot %u tid %u srb 0x%x status 0x%x", index, transactionID, srbResponse, scsiStatus);
                iv->statErrors++;
                CompleteSlot(index, kSCSITaskStatus_CHECK_CONDITION, kSCSIServiceResponse_TASK_COMPLETE, 0, kSenseHardwareError, 0x44);
            } else {
                const uint64_t bytes = transferred < length ? transferred : length;
                iv->statReads++;
                iv->statReadBytes += bytes;
                const uint32_t bucket = length <= 0x1000 ? 0 : (length <= 0x10000 ? 1 : (length <= 0x40000 ? 2 : 3));
                const uint64_t elapsed = mach_absolute_time() - iv->slots[index].submitTime;
                iv->latencyCount[bucket]++;
                iv->latencyTicks[bucket] += elapsed;
                if (elapsed > iv->latencyMaxTicks[bucket]) {
                    iv->latencyMaxTicks[bucket] = elapsed;
                }
                CompleteSlot(index, kSCSITaskStatus_GOOD, kSCSIServiceResponse_TASK_COMPLETE, bytes, 0, 0);
            }
            completed++;
        }
        // Hand the response list back to the Drobo; it may post the next burst at once.
        RegWrite32(iv, kDroboRegOutgoingDoorbellCause, ~kOutBitSCSIResponse);
    }
    // Keep the published counters fresh while there is traffic: at most once a second.
    if (completed != 0) {
        const uint64_t now = mach_absolute_time();
        if (now - iv->lastPublishTicks > 1000 * iv->ticksPerMillisecond) {
            iv->lastPublishTicks = now;
            PublishStatus(this, iv);
        }
    }
    return completed;
}

// Sends as many pending requests as the device will take, in bursts.
void
DroboSCSIController::Pump()
{
    DroboSCSIController_IVars * iv = ivars;

    while (iv->ready && !iv->dead && iv->pendingCount != 0 && iv->inflight < iv->maxInflight) {
        // The Drobo must have consumed the previous burst (In[0] cause bit clear).
        uint32_t cause = 0;
        for (uint32_t spin = 0; spin < 100; spin++) {
            cause = Reg32(iv, kDroboRegIncomingDoorbellCause);
            if (cause == 0xFFFFFFFF || (cause & kInBitSCSIRequest) == 0) {
                break;
            }
            IODelay(10);
        }
        if (cause == 0xFFFFFFFF) {
            FailAllSlots("device-removed");
            return;
        }
        if ((cause & kInBitSCSIRequest) != 0) {
            iv->statDoorbellBusy++;
            break;                                      // the timer retries
        }

        uint32_t burst = iv->pendingCount;
        if (burst > iv->burstMax) {
            burst = iv->burstMax;
        }
        if (burst > iv->maxInflight - iv->inflight) {
            burst = iv->maxInflight - iv->inflight;
        }
        const uint64_t now = mach_absolute_time();
        for (uint32_t i = 0; i < burst; i++) {
            const uint32_t index = iv->pendingRing[iv->pendingHead];
            iv->pendingHead = (iv->pendingHead + 1) % kDroboSlotCount;
            iv->pendingCount--;

            DroboSlot * slot = &iv->slots[index];
            // Transaction IDs are assigned here so they reach the device strictly in order.
            slot->transactionID = iv->nextTransactionID++;
            slot->submitted     = true;
            slot->submitTime    = now;
            DroboBlockRequest * request = (DroboBlockRequest *) (iv->requestVA + index * kDroboSlotSize);
            request->header.transactionIDCopy = slot->transactionID;
            request->transactionID            = slot->transactionID;

            const uint32_t entry = iv->requestListOffset + 8 + i * (uint32_t) sizeof(DroboQueueEntry);
            PortWrite32(iv, entry + 0x0, (uint32_t) (iv->requestBusAddress + index * kDroboSlotSize));
            PortWrite32(iv, entry + 0x4, 0);
            PortWrite32(iv, entry + 0x8, request->header.totalLength);
            PortWrite32(iv, entry + 0xC, slot->transactionID);
            iv->inflight++;
        }
        PortWrite32(iv, iv->requestListOffset + 4, burst);
        RegWrite32(iv, kDroboRegIncomingDoorbellCause, kInBitSCSIRequest);

        iv->statBursts++;
        if (burst > iv->statPeakBurst)          { iv->statPeakBurst = burst; }
        if (iv->inflight > iv->statPeakInflight) { iv->statPeakInflight = iv->inflight; }
    }
    if (iv->inflight != 0 || iv->pendingCount != 0 || iv->tmInflight) {
        ArmTimer();
    }
}

// Validates a READ and queues it. Returns true when `response` already holds the final
// answer (error or zero-length), false when the task was queued and completes later.
bool
DroboSCSIController::QueueRead(const SCSIUserParallelTask * task, OSAction * completion,
                               SCSIUserParallelResponse * response, uint32_t lun, uint64_t lba, uint32_t blocks)
{
    DroboSCSIController_IVars * iv = ivars;
    const uint64_t length = (uint64_t) blocks * 512;

    if (blocks == 0) {
        return true;                                        // GOOD, nothing to transfer
    }
    if (lba + blocks > iv->luns[lun].blockCount || lba + blocks < lba) {
        SetSense(response, kSenseIllegalRequest, 0x21, 0x00);   // LBA out of range
        return true;
    }
    if (length > iv->maxTransferSize || length > task->fRequestedTransferCount ||
        task->fBufferIOVMAddr == 0 || ((task->fBufferIOVMAddr + length - 1) >> 32) != 0) {
        DLog("read rejected: len 0x%llx requested 0x%llx iova 0x%llx", length,
             task->fRequestedTransferCount, task->fBufferIOVMAddr);
        iv->statErrors++;
        SetSense(response, kSenseIllegalRequest, 0x24, 0x00);
        return true;
    }
    if (iv->dead) {
        response->fServiceResponse = kSCSIServiceResponse_SERVICE_DELIVERY_OR_TARGET_FAILURE;
        return true;
    }

    uint32_t index = kDroboSlotCount;
    for (uint32_t i = 0; i < kDroboSlotCount; i++) {
        if (!iv->slots[i].inUse) {
            index = i;
            break;
        }
    }
    if (index == kDroboSlotCount) {
        response->fCompletionStatus = kSCSITaskStatus_TASK_SET_FULL;    // the family retries
        return true;
    }

    DroboSlot * slot = &iv->slots[index];
    slot->inUse      = true;
    slot->submitted  = false;
    slot->length     = length;
    slot->targetID   = task->fTargetID;
    slot->taskID     = task->fControllerTaskIdentifier;
    slot->completion = completion;
    completion->retain();

    uint8_t * memory = iv->requestVA + index * kDroboSlotSize;
    bzero(memory, kDroboSlotSize);
    DroboBlockRequest * request = (DroboBlockRequest *) memory;
    DroboSGLEntry *     sgl     = (DroboSGLEntry *) (memory + sizeof(DroboBlockRequest));
    request->header.hostDataBusAddress = iv->requestBusAddress + index * kDroboSlotSize;
    request->header.queueIndex         = index;             // echoed back in the response entry
    request->header.hostCookie         = task->fControllerTaskIdentifier;
    request->header.totalLength        = (uint32_t) sizeof(DroboBlockRequest) + (uint32_t) sizeof(DroboSGLEntry);
    request->header.kind               = kDroboRequestKindBlockIO;
    request->operation                 = kDroboBlockOpRead;
    request->transferLength            = (uint32_t) length;
    request->hostSGLPointer            = (uint64_t) (uintptr_t) sgl;
    request->lun                       = lun;
    request->blockCount                = blocks;
    request->lba                       = lba;
    sgl[0].address                     = task->fBufferIOVMAddr;
    sgl[0].length                      = (uint32_t) length;
    sgl[1].length                      = 0;                 // terminator

    iv->pendingRing[(iv->pendingHead + iv->pendingCount) % kDroboSlotCount] = (uint8_t) index;
    iv->pendingCount++;
    return false;
}

// MARK: Health (management pages over the passthrough channel)

static uint32_t
HealthPageLength(DroboSCSIController_IVars * iv, uint8_t page)
{
    switch (page) {
        case 0x01: return 4 + 11;                               // config
        case 0x02: return 4 + 32;                               // capacity
        case 0x03: return 4 + 1 + 72 * iv->healthSlotCount;     // slot info
        case 0x05: return 4 + 38;                               // settings (name, clock)
        case 0x06: return 4 + 2;                                // protocol version
        case 0x08: return 4 + 310;                              // firmware
        case 0x09: return 4 + 8;                                // status, relayout count
        default:   return 0;
    }
}

void
DroboSCSIController::PublishHealth()
{
    DroboSCSIController_IVars * iv = ivars;
    OSDictionary * health = OSDictionary::withCapacity(16);
    if (health == nullptr) {
        return;
    }
    static const char * const kKeys[kHealthPageCount] = {
        "Config", "Capacity", "Slots", "Settings", "Protocol", "Firmware", "Status"
    };
    for (uint32_t i = 0; i < kHealthPageCount; i++) {
        if (iv->healthLength[i] != 0) {
            OSData * data = OSData::withBytes(iv->healthData[i], iv->healthLength[i]);
            if (data != nullptr) {
                health->setObject(kKeys[i], data);
                data->release();
            }
        }
    }
    DictSetNumber(health, "Cycles", iv->healthCycles);
    DictSetNumber(health, "Errors", iv->healthErrors);
    DictSetNumber(health, "LastSRBResponse", iv->healthLastSRB);
    DictSetNumber(health, "LastSCSIStatus", iv->healthLastStatus);
    health->setObject("Available", iv->healthAvailable ? kOSBooleanTrue : kOSBooleanFalse);

    OSDictionary * wrapper = OSDictionary::withCapacity(1);
    if (wrapper != nullptr) {
        wrapper->setObject("DroboHealth", health);
        SetProperties(wrapper);
        wrapper->release();
    }
    health->release();
}

// Sends the MODE SENSE for the current health page. Returns false if nothing was sent.
bool
DroboSCSIController::HealthSend()
{
    DroboSCSIController_IVars * iv = ivars;
    if (!iv->ready || iv->dead || iv->stopping || !iv->healthAvailable || iv->tmInflight ||
        iv->healthPage >= kHealthPageCount) {
        return false;
    }
    const uint32_t cause = Reg32(iv, kDroboRegIncomingDoorbellCause);
    if (cause == 0xFFFFFFFF || (cause & kInBitTMRequest) != 0) {
        return false;                               // previous request not consumed yet
    }

    const uint8_t  page   = kHealthPages[iv->healthPage];
    const uint32_t length = HealthPageLength(iv, page);
    uint8_t * memory = iv->requestVA + kHealthSlot * kDroboSlotSize;
    bzero(memory, kDroboSlotSize);
    bzero(iv->requestVA + kHealthDataOffset, kHealthPageMax);

    DroboPassthroughRequest * request = (DroboPassthroughRequest *) memory;
    DroboSGLEntry *           sgl     = (DroboSGLEntry *) (memory + sizeof(DroboPassthroughRequest));
    request->header.hostDataBusAddress = iv->requestBusAddress + kHealthSlot * kDroboSlotSize;
    request->header.queueIndex         = 0;
    request->header.hostCookie         = 0x4845414C;            // "HEAL"
    request->header.totalLength        = (uint32_t) sizeof(DroboPassthroughRequest) + (uint32_t) sizeof(DroboSGLEntry);
    request->header.kind               = kDroboRequestKindPassthrough;
    // One data segment: the original driver then puts the buffer's bus address straight into
    // the pointer field and sets the "direct buffer" flag instead of describing an SGL.
    // (Without one of the two mode flags the Drobo answers SRB response 4, error.)
    request->flags                     = kDroboPassthroughDataInOrNone | kDroboPassthroughDirectBuffer;
    request->transferLength            = length;
    request->hostSGLPointer            = iv->requestBusAddress + kHealthDataOffset;
    // MODE SENSE(10): page 0x3A (vendor), sub-page = the management page, big-endian length.
    request->cdb[0] = 0x5A;
    request->cdb[2] = 0x3A;
    request->cdb[3] = page;
    request->cdb[7] = (uint8_t) (length >> 8);
    request->cdb[8] = (uint8_t) length;
    sgl[0].address = iv->requestBusAddress + kHealthDataOffset;
    sgl[0].length  = 0;                             // cleared in direct-buffer mode, as the kext does

    // The original driver uses transaction ID 0 on this channel.
    const uint32_t entry = iv->tmRequestListOffset + 8;
    PortWrite32(iv, entry + 0x0, (uint32_t) request->header.hostDataBusAddress);
    PortWrite32(iv, entry + 0x4, 0);
    PortWrite32(iv, entry + 0x8, request->header.totalLength);
    PortWrite32(iv, entry + 0xC, 0);
    PortWrite32(iv, iv->tmRequestListOffset + 4, 1);
    RegWrite32(iv, kDroboRegIncomingDoorbellCause, kInBitTMRequest);

    iv->tmInflight = true;
    iv->tmSubmitTime = mach_absolute_time();
    ArmTimer();
    return true;
}

// Called from ProcessCompletions when the passthrough response bit is set.
void
DroboSCSIController::HealthResponse()
{
    DroboSCSIController_IVars * iv = ivars;
    const uint32_t base = iv->tmResponseListOffset + kDroboResponseListEntriesOffset;
    const uint64_t transferred = (uint64_t) Port32(iv, base + 0x08) | ((uint64_t) Port32(iv, base + 0x0C) << 32);
    const uint32_t srbResponse = Port32(iv, base + 0x14);
    const uint32_t scsiStatus  = Port32(iv, base + 0x18);
    RegWrite32(iv, kDroboRegOutgoingDoorbellCause, ~kOutBitTMResponse);

    if (!iv->tmInflight || iv->healthPage >= kHealthPageCount) {
        return;
    }
    iv->tmInflight = false;
    iv->healthLastSRB = srbResponse;
    iv->healthLastStatus = scsiStatus;

    const uint32_t index = iv->healthPage;
    const uint32_t wanted = HealthPageLength(iv, kHealthPages[index]);
    if ((srbResponse == kDroboSRBResponseSuccess || srbResponse == kDroboSRBResponseShort) && scsiStatus == 0) {
        uint32_t length = transferred != 0 && transferred < wanted ? (uint32_t) transferred : wanted;
        if (length > kHealthPageMax) {
            length = kHealthPageMax;
        }
        memcpy(iv->healthData[index], iv->requestVA + kHealthDataOffset, length);
        iv->healthLength[index] = length;
        // The config page gives the real slot count for the slot-info page.
        if (kHealthPages[index] == 0x01 && length >= 5) {
            const uint8_t slots = iv->healthData[index][4];
            if (slots >= 1 && slots <= 9) {     // the 8D reports 9: eight bays plus the mSATA bay
                iv->healthSlotCount = slots;
            }
        }
    } else {
        iv->healthErrors++;
    }

    iv->healthPage++;
    if (iv->healthPage >= kHealthPageCount) {
        iv->healthCycles++;
        PublishHealth();
    } else {
        HealthSend();
    }
}

void
IMPL(DroboSCSIController, HandleHealthTimer)
{
    DroboSCSIController_IVars * iv = ivars;
    if (iv->stopping) {
        return;
    }
    // A health query that never came back disables health polling; block I/O is unaffected.
    if (iv->tmInflight && mach_absolute_time() - iv->tmSubmitTime > 10000 * iv->ticksPerMillisecond) {
        iv->tmInflight = false;
        iv->healthAvailable = false;
        iv->healthErrors++;
        PublishHealth();
    }
    if (!iv->tmInflight) {
        iv->healthPage = 0;
        HealthSend();
    }
    if (iv->healthTimer != nullptr) {
        const uint64_t period = (iv->healthCycles == 0 ? 1000 : 5000) * iv->ticksPerMillisecond;
        iv->healthTimer->WakeAtTime(kIOTimerClockMachAbsoluteTime, mach_absolute_time() + period, period / 10);
    }
}

void
IMPL(DroboSCSIController, HandleInterrupt)
{
    DroboSCSIController_IVars * iv = ivars;
    iv->statInterrupts++;
    iv->statCompletedByInterrupt += ProcessCompletions();
    Pump();
}

void
IMPL(DroboSCSIController, HandleTimer)
{
    DroboSCSIController_IVars * iv = ivars;
    iv->timerArmed = false;
    iv->statTimerFires++;
    if (iv->stopping) {
        return;
    }
    iv->statCompletedByTimer += ProcessCompletions();

    // Anything the device has held for too long means the link is gone or we are out of step.
    const uint64_t now = mach_absolute_time();
    const uint64_t limit = (uint64_t) kDroboTaskTimeoutMS * iv->ticksPerMillisecond;
    for (uint32_t i = 0; i < kDroboSlotCount && !iv->dead; i++) {
        if (iv->slots[i].inUse && iv->slots[i].submitted && now - iv->slots[i].submitTime > limit) {
            DLog("request timeout: slot %u tid %u", i, iv->slots[i].transactionID);
            FailAllSlots("response-timeout");
        }
    }
    Pump();
    if ((iv->statTimerFires & 0x3FF) == 0) {
        PublishStatus(this, iv);
    }
}

// Returns true when `response` is final, false when the task was queued for the device.
bool
DroboSCSIController::HandleTask(const SCSIUserParallelTask * task, OSAction * completion, SCSIUserParallelResponse * response)
{
    DroboSCSIController_IVars * iv = ivars;
    const uint8_t * cdb    = task->fCommandDescriptorBlock;
    const uint8_t   opcode = cdb[0];
    const uint32_t  lun    = (((uint32_t) task->fLogicalUnitBytes[0] & 0x3F) << 8) | task->fLogicalUnitBytes[1];
    const bool      lunOK  = (lun < 32) && iv->luns[lun].present;
    uint8_t         data[512] = {};

    InitResponse(response, task);
    iv->statTasks++;
    iv->lastOpcode = opcode;
    if (iv->statTasks <= 64 || (iv->statTasks & 0xFF) == 0) {
        PublishStatus(this, iv);
    }

    if (!iv->ready) {
        SetSense(response, kSenseNotReady, 0x04, 0x01);     // becoming ready
        return true;
    }

    switch (opcode) {
        case 0x12: {                                        // INQUIRY
            const bool    evpd = (cdb[1] & 1) != 0;
            const uint8_t page = cdb[2];
            uint32_t length = 0;
            if (!evpd) {
                data[0] = lunOK ? 0x00 : 0x7F;              // direct access, or "no device here"
                data[2] = 0x05;                             // SPC-3
                data[3] = 0x02;
                data[4] = 31;
                PadCopy(&data[8], "Drobo", 8);
                PadCopy(&data[16], "8D", 16);
                PadCopy(&data[32], "DK01", 4);
                length = 36;
            } else if (!lunOK) {
                SetSense(response, kSenseIllegalRequest, 0x25, 0x00);
                return true;
            } else if (page == 0x00) {
                data[1] = 0x00; data[3] = 2; data[4] = 0x00; data[5] = 0x80;
                length = 6;
            } else if (page == 0x80) {
                const uint8_t serialLength = (uint8_t) strlen(iv->serial);
                data[1] = 0x80; data[3] = serialLength;
                memcpy(&data[4], iv->serial, serialLength);
                length = 4 + serialLength;
            } else {
                SetSense(response, kSenseIllegalRequest, 0x24, 0x00);
                return true;
            }
            response->fBytesTransferred = CopyToTask(task, data, length);
            return true;
        }
        case 0xA0: {                                        // REPORT LUNS
            uint32_t count = 0;
            for (uint32_t i = 0; i < 32; i++) {
                if (iv->luns[i].present) {
                    data[8 + 8 * count + 1] = (uint8_t) i;
                    count++;
                }
            }
            PutBE32(&data[0], count * 8);
            response->fBytesTransferred = CopyToTask(task, data, 8 + count * 8);
            return true;
        }
        default:
            break;
    }

    if (!lunOK) {
        SetSense(response, kSenseIllegalRequest, 0x25, 0x00);   // logical unit not supported
        return true;
    }
    const DroboLUN & unit = iv->luns[lun];

    switch (opcode) {
        case 0x00:                                          // TEST UNIT READY
        case 0x1B:                                          // START STOP UNIT (no-op)
        case 0x1E:                                          // PREVENT ALLOW MEDIUM REMOVAL (no-op)
        case 0x35:                                          // SYNCHRONIZE CACHE 10 (nothing to flush)
        case 0x91:                                          // SYNCHRONIZE CACHE 16
            return true;

        case 0x03:                                          // REQUEST SENSE: no sense
            data[0] = 0x70; data[7] = 10;
            response->fBytesTransferred = CopyToTask(task, data, 18);
            return true;

        case 0x25: {                                        // READ CAPACITY 10
            const uint64_t last = unit.blockCount - 1;
            PutBE32(&data[0], last > 0xFFFFFFFEull ? 0xFFFFFFFFu : (uint32_t) last);
            PutBE32(&data[4], 512);
            response->fBytesTransferred = CopyToTask(task, data, 8);
            return true;
        }
        case 0x9E:                                          // SERVICE ACTION IN 16
            if ((cdb[1] & 0x1F) == 0x10) {                  // READ CAPACITY 16
                PutBE64(&data[0], unit.blockCount - 1);
                PutBE32(&data[8], 512);
                response->fBytesTransferred = CopyToTask(task, data, 32);
                return true;
            }
            SetSense(response, kSenseIllegalRequest, 0x24, 0x00);
            return true;

        case 0x1A:                                          // MODE SENSE 6: header only, write-protected
            data[0] = 3; data[2] = 0x80;
            response->fBytesTransferred = CopyToTask(task, data, 4);
            return true;
        case 0x5A:                                          // MODE SENSE 10
            data[1] = 6; data[3] = 0x80;
            response->fBytesTransferred = CopyToTask(task, data, 8);
            return true;

        case 0x08:                                          // READ 6
            return QueueRead(task, completion, response, lun, ((uint32_t) (cdb[1] & 0x1F) << 16) | BE16(&cdb[2]), cdb[4] ? cdb[4] : 256);
        case 0x28:                                          // READ 10
            return QueueRead(task, completion, response, lun, BE32(&cdb[2]), BE16(&cdb[7]));
        case 0xA8:                                          // READ 12
            return QueueRead(task, completion, response, lun, BE32(&cdb[2]), BE32(&cdb[6]));
        case 0x88:                                          // READ 16
            return QueueRead(task, completion, response, lun, BE64(&cdb[2]), BE32(&cdb[10]));

        // Everything that could modify the volume is refused here and never reaches the Drobo.
        case 0x0A: case 0x2A: case 0xAA: case 0x8A:         // WRITE 6/10/12/16
        case 0x2E: case 0xAE: case 0x8E:                    // WRITE AND VERIFY
        case 0x41: case 0x93:                               // WRITE SAME
        case 0x42:                                          // UNMAP
        case 0x04:                                          // FORMAT UNIT
        case 0x3B:                                          // WRITE BUFFER
        case 0x15: case 0x55:                               // MODE SELECT
        case 0x48:                                          // SANITIZE
            iv->statRejectedWrites++;
            SetSense(response, kSenseDataProtect, 0x27, 0x00);      // write protected
            return true;

        default:
            SetSense(response, kSenseIllegalRequest, 0x20, 0x00);   // invalid command operation code
            return true;
    }
    return true;
}

kern_return_t
IMPL(DroboSCSIController, UserProcessParallelTask)
{
    if (ivars->probeQueue == nullptr || ivars->stopping) {
        *response = kSCSIServiceResponse_SERVICE_DELIVERY_OR_TARGET_FAILURE;
        return kIOReturnNotReady;
    }
    const SCSIUserParallelTask task = parallelRequest;
    ivars->statReceived++;
    completion->retain();
    ivars->probeQueue->DispatchAsync(^{
        SCSIUserParallelResponse result;
        const bool finished = HandleTask(&task, completion, &result);

        // Trace the first 32 tasks so the registry shows exactly what the family asked for.
        const uint32_t slot = ivars->traceCount++;
        if (slot < 32) {
            ivars->trace[slot][0] = (uint32_t) task.fCommandDescriptorBlock[0] | ((uint32_t) task.fCommandSize << 8) |
                                    ((uint32_t) task.fTransferDirection << 16) | ((uint32_t) task.fCommandDescriptorBlock[1] << 24);
            ivars->trace[slot][1] = ((uint32_t) task.fLogicalUnitBytes[0] << 8) | task.fLogicalUnitBytes[1] |
                                    ((uint32_t) task.fTargetID << 16);
            ivars->trace[slot][2] = (uint32_t) task.fRequestedTransferCount;
            ivars->trace[slot][3] = (uint32_t) task.fControllerTaskIdentifier;
            ivars->trace[slot][4] = finished ? ((uint32_t) result.fCompletionStatus | ((uint32_t) result.fServiceResponse << 8) |
                                                ((uint32_t) result.fSenseBuffer[2] << 16) | ((uint32_t) result.fSenseBuffer[12] << 24))
                                             : 0xFFFFFFFF;      // queued for the device
            ivars->trace[slot][5] = task.fTimeoutInMilliSec;
        }

        if (!finished) {
            // Queued: the slot holds its own reference to the completion action. Drain anything
            // already finished, then send whatever fits in the next burst.
            completion->release();
            ProcessCompletions();
            Pump();
            return;
        }

        // Driver-answered commands finish instantly, so complete them from the Default queue:
        // UserProcessParallelTask runs there, so this cannot overtake its return.
        const SCSIUserParallelResponse answer = result;
        IODispatchQueue * defaultQueue = ivars->defaultQueue;
        void (^complete)(void) = ^{
            ParallelTaskCompletion(completion, answer);
            ivars->statCompleted++;
            completion->release();
            if (slot < 32) {
                PublishStatus(this, ivars);
            }
        };
        if (defaultQueue != nullptr) {
            defaultQueue->DispatchAsync(complete);
        } else {
            complete();
        }
    });
    *response = kSCSIServiceResponse_Request_In_Process;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserMapBundledParallelTaskCommandAndResponseBuffers)
{
    // Returning an error tells the family to use the non-bundled UserProcessParallelTask path.
    return kIOReturnUnsupported;
}

void
IMPL(DroboSCSIController, UserProcessBundledParallelTasks)
{
}

// MARK: Task management (the original driver also treats these as no-ops)

kern_return_t
IMPL(DroboSCSIController, UserAbortTaskRequest)
{
    ivars->statTaskManagement++;
    *response = kSCSIServiceResponse_TASK_COMPLETE;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserAbortTaskSetRequest)
{
    ivars->statTaskManagement++;
    *response = kSCSIServiceResponse_TASK_COMPLETE;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserClearACARequest)
{
    ivars->statTaskManagement++;
    *response = kSCSIServiceResponse_TASK_COMPLETE;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserClearTaskSetRequest)
{
    ivars->statTaskManagement++;
    *response = kSCSIServiceResponse_TASK_COMPLETE;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserLogicalUnitResetRequest)
{
    ivars->statTaskManagement++;
    *response = kSCSIServiceResponse_TASK_COMPLETE;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(DroboSCSIController, UserTargetResetRequest)
{
    ivars->statTaskManagement++;
    *response = kSCSIServiceResponse_TASK_COMPLETE;
    return kIOReturnSuccess;
}
