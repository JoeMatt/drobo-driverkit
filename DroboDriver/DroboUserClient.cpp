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
