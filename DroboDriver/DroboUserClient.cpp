//
//  DroboUserClient.cpp
//

#include <os/log.h>

#include <DriverKit/DriverKit.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/OSCollections.h>

#include "DroboSCSIController.h"
#include "DroboUserClient.h"

// Selector 0 input. Must match DroboCommand in the host app.
struct DroboAppCommandInput
{
    uint32_t command;
    uint32_t argument;
    char     name[32];
};

// Selector 3 input: a volume command (protocol notes 11.26). Must match the host app.
struct DroboVolumeCommandInput
{
    uint32_t command;       // 1 create, 2 delete, 3 reset, 4 reset with a new volume size
    uint32_t confirm;
    uint64_t sizeBytes;     // create
    uint32_t unit;          // delete
    uint32_t uniqueID;      // delete
    char     serial[32];    // the Drobo's serial number, as the person typed it
};

struct DroboUserClient_IVars
{
    DroboSCSIController * controller;
};

bool
DroboUserClient::init()
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(DroboUserClient_IVars, 1);
    return ivars != nullptr;
}

void
DroboUserClient::free()
{
    if (ivars != nullptr) {
        OSSafeReleaseNULL(ivars->controller);
        IOSafeDeleteNULL(ivars, DroboUserClient_IVars, 1);
    }
    super::free();
}

kern_return_t
IMPL(DroboUserClient, Start)
{
    ivars->controller = OSDynamicCast(DroboSCSIController, provider);
    if (ivars->controller == nullptr) {
        return kIOReturnBadArgument;
    }
    ivars->controller->retain();
    return Start(provider, SUPERDISPATCH);
}

kern_return_t
IMPL(DroboUserClient, Stop)
{
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t
DroboUserClient::ExternalMethod(uint64_t selector,
                                IOUserClientMethodArguments * arguments,
                                const IOUserClientMethodDispatch * dispatch,
                                OSObject * target,
                                void * reference)
{
    // Selector 1: a slice of the event log read last. Input: u32 offset. Output: up to 4096 bytes.
    // Selector 2: the same for the output of the shell command run last.
    if (selector == 1 || selector == 2) {
        if (arguments == nullptr || arguments->structureInput == nullptr ||
            arguments->structureInput->getLength() < sizeof(uint32_t) ||
            ivars == nullptr || ivars->controller == nullptr) {
            return kIOReturnBadArgument;
        }
        uint32_t offset = 0;
        memcpy(&offset, arguments->structureInput->getBytesNoCopy(), sizeof(offset));
        uint32_t capacity = 4096;
        if (arguments->structureOutputMaximumSize < capacity) {
            capacity = (uint32_t) arguments->structureOutputMaximumSize;
        }
        if (capacity == 0) {
            return kIOReturnBadArgument;
        }
        uint8_t * slice = IONewZero(uint8_t, 4096);
        if (slice == nullptr) {
            return kIOReturnNoMemory;
        }
        uint32_t copied = 0;
        kern_return_t result = selector == 1 ? ivars->controller->CopyLog(offset, slice, capacity, &copied)
                                             : ivars->controller->CopyShell(offset, slice, capacity, &copied);
        if (result == kIOReturnSuccess) {
            arguments->structureOutput = OSData::withBytes(slice, copied);
            if (arguments->structureOutput == nullptr) {
                result = kIOReturnNoMemory;
            }
        }
        IOSafeDeleteNULL(slice, uint8_t, 4096);
        return result;
    }
    if (selector == 3) {
        if (arguments == nullptr || arguments->structureInput == nullptr ||
            arguments->structureInput->getLength() < sizeof(DroboVolumeCommandInput) ||
            ivars == nullptr || ivars->controller == nullptr) {
            return kIOReturnBadArgument;
        }
        DroboVolumeCommandInput volume;
        memcpy(&volume, arguments->structureInput->getBytesNoCopy(), sizeof(volume));
        char serial[33] = {};
        memcpy(serial, volume.serial, sizeof(volume.serial));
        return ivars->controller->VolumeCommand(volume.command, volume.confirm, volume.sizeBytes, volume.unit,
                                                volume.uniqueID, serial);
    }
    if (selector != 0 || arguments == nullptr || arguments->structureInput == nullptr ||
        arguments->structureInput->getLength() < sizeof(DroboAppCommandInput) ||
        ivars == nullptr || ivars->controller == nullptr) {
        return kIOReturnBadArgument;
    }
    DroboAppCommandInput input;
    memcpy(&input, arguments->structureInput->getBytesNoCopy(), sizeof(input));
    char name[33] = {};
    memcpy(name, input.name, sizeof(input.name));
    return ivars->controller->AppCommand(input.command, input.argument, name);
}
