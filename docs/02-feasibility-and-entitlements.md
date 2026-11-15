# Feasibility: a DriverKit driver for the Drobo 8D

Written 2026-11-14. Target: Mac Studio (M4 Max, macOS 27.2.1, SIP enabled), Xcode with the
DriverKit 27.0 SDK. Protocol details are in
[01-protocol-reverse-engineering.md](01-protocol-reverse-engineering.md).

## Verdict

**Technically feasible, and for personal use it does not need Reduced Security, a kext, or
SIP changes.** The one point documentation left open, whether a development-signed dext with
the development PCI entitlement activates on a SIP-enabled Mac, was tested on the Studio on
2026-11-14 and it does (see "Account state" below).

The engineering risk is in the hardware bring-up, not in Apple's frameworks: the protocol is
fully custom and has only been read statically.

## Why the architecture fits

| Kext mechanism | DriverKit equivalent | Fit |
|---|---|---|
| `IOSCSIParallelInterfaceController` subclass | `IOUserSCSIParallelInterfaceController` (SCSIControllerDriverKit) | Direct. Same callbacks with a `User` prefix. |
| `IOPCIDevice` + `mapDeviceMemoryWithIndex` | `IOPCIDevice` (PCIDriverKit): `Open`, `GetBARInfo`, `MemoryRead32/Write32` | Direct. MMIO goes through accessor calls instead of raw pointers. |
| `IOFilterInterruptEventSource` on MSI | `ConfigureInterrupts(kIOInterruptTypePCIMessaged)` + `IOInterruptDispatchSource` | Direct. No primary-interrupt filter; the "clear cause" write moves into the handler. |
| `IODMACommand` (32-bit, little-endian) | `UserGetDMASpecification(numAddressBits = 32, kDMAOutputSegmentLittle32)`; the kernel hands each task a ready bus address in `fBufferIOVMAddr` | Better than the kext: the data buffer arrives as one bus address, so the SGL is one entry and the bounce-buffer code goes away. |
| Request structures in HBA task data | An `IOBufferMemoryDescriptor` pool mapped once through DriverKit `IODMACommand` | Straightforward. |
| Self-describing doorbell tables | Same interpreter in user space | Trivial. |
| Thunderbolt hot-plug, sleep/wake | `IOPCITunnelCompatible` personality key, `SetPowerState` | Supported; needs care. |

Nothing in the kext needs a kernel-only facility. Apple silicon restrictions that matter
(no I/O space, MSI only) are already how the kext behaves.

Expected cost: throughput. Each MMIO access is a call into the kernel, and each task crosses the
user/kernel boundary. The protocol batches requests in bursts, which limits the damage. A
spinning-disk Drobo is unlikely to be bottlenecked by this, but it is unmeasured.

## Entitlements

### The dext

| Entitlement | Value | Purpose |
|---|---|---|
| `com.apple.developer.driverkit` | `true` | Run as a driver extension. |
| `com.apple.developer.driverkit.transport.pci` | array of match dictionaries | Permission to attach to a PCI device. |
| `com.apple.developer.driverkit.family.scsicontroller` | `true` | Permission to subclass the SCSI controller family. |

### The host app

| Entitlement | Value | Purpose |
|---|---|---|
| `com.apple.developer.system-extension.install` | `true` | Call `OSSystemExtensionRequest` to activate the dext. |

### Development variants (no Apple approval)

Per Apple DTS (forum threads linked at the bottom), every DriverKit entitlement now has a
development variant that is "available on all paid developer accounts without any special
approval". The PCI one was added in late 2025 and appears in the developer portal as
**"DriverKit PCI (development)"**. Its value is fixed:

```xml
<key>com.apple.developer.driverkit.transport.pci</key>
<array>
    <dict>
        <key>IOPCIPrimaryMatch</key>
        <string>0xFFFFFFFF&amp;0x00000000</string>
    </dict>
</array>
```

That mask matches any vendor/device, so it covers `0x4452:0x3844` without anyone "owning"
vendor ID `0x4452`. Constraints:

- Only valid in **development-signed** builds (Apple Development certificate + development
  provisioning profile).
- The build only runs on Macs **registered in your developer account when the profile was
  generated**. The Studio (and the MacBook, if wanted) must be registered devices.
- The dext's `.entitlements` file must match the profile's value **exactly**, or activation is
  aborted. The narrowing to the Drobo happens in `Info.plist` (`IOPCIMatch`), not in the
  entitlement.
- Development profiles expire after a year; rebuild and reinstall annually.
- The development PCI entitlement does not match built-in hardware. A Thunderbolt-tunnelled
  device is external, so this should not apply.

### How to get them (your Apple Developer account, team S32Z3HMYVQ)

Portal changes are yours to make or approve; I have not touched the account.

1. Certificates, Identifiers & Profiles → Devices: confirm the Mac Studio's Provisioning UDID
   is registered (System Information → Hardware → Provisioning UDID).
2. Identifiers → register two explicit App IDs:
   - `com.joemattiello.DroboDriverKit` with capability **System Extension**.
   - `com.joemattiello.DroboDriverKit.driver` with capabilities **DriverKit**,
     **DriverKit PCI (development)**, **DriverKit Family SCSI Controller (development)**.
   (Capability labels can differ slightly; the PCI one is named as quoted by DTS.)
3. Either let Xcode's automatic signing generate the development profiles, or create two macOS
   App Development profiles by hand that include the Studio. A profile cannot gain entitlements
   after creation: if a capability is added later, generate a new profile.
4. Open the project, select the team, build. If Xcode reports an entitlement mismatch, fix the
   `.entitlements` file to match the profile, not the other way round.

#### Account state as of 2026-11-14

Done through the App Store Connect API and Xcode automatic signing:

- Mac Studio registered as a device.
- `com.joemattiello.DroboDriverKit` with `SYSTEM_EXTENSION_INSTALL`.
- `com.joemattiello.DroboDriverKit.driver` with `DRIVERKIT_PUBLIC` and
  `DRIVERKIT_FAMILY_SCSICONTROLLER_PUB`. Xcode enabled both itself, with no Apple request.

The PCI capability could not be added by the public API (no capability type for it) or by
Xcode ("needs to be assigned to your team and bundle identifier by Apple"). It had to be
ticked by hand in the portal on the `.driver` identifier, which worked without any Apple
request.

Result: `xcodebuild -allowProvisioningUpdates` now succeeds. The dext is signed with
Apple Development, carries `driverkit`, `family.scsicontroller` and
`transport.pci = [{IOPCIPrimaryMatch: 0xFFFFFFFF&0x00000000}]`, and its embedded profile
("DriverKit Team Provisioning Profile", expires 2027-11-03) includes the Studio's UDID.

**Activation confirmed 2026-11-14.** Installed to `/Applications` on the Studio, activated from
the host app, approved under Driver Extensions. `systemextensionsctl list` reports
`com.joemattiello.DroboDriverKit.driver (0.1.0/1) [activated enabled]` with
`csrutil status` = enabled and no boot-policy change. Path A works with SIP on.
Once the Drobo was cabled with a Thunderbolt 3 cable it enumerated and the dext matched and
started on it (details in section 11 of the protocol notes).

If "DriverKit PCI (development)" is missing from the portal for your team (one developer
reported that in Oct 2025; DTS said it was present on the teams they checked), that is a
portal problem to raise with Apple, and it blocks the no-security-change path.

## What is possible for personal use

### Path A: development signing. **Recommended.**

- No Apple grant, no vendor ID, no notarization.
- Install: copy the host app to `/Applications` on the Studio, launch it, press Activate,
  approve in System Settings → General → Login Items & Extensions → Driver Extensions. That
  approval is a normal user consent prompt, not a security downgrade.
- Boot policy stays at Full Security. No kexts. SIP stays on.
- Limits: only your registered Macs; yearly re-sign; cannot be handed to other Drobo owners.

**Unverified point.** Apple's documentation page on testing system extensions still describes
disabling SIP as the way to load non-notarized builds, while DTS describes a "newer, much
simpler process" using development profiles and says the older flow "required disabling SIP
and local signing". I found no Apple statement that says in so many words "a
development-profile dext loads with SIP enabled". Third-party reports of SIP-enabled failures
exist but trace to signing mistakes (one was an accidental arm64e slice). Treat Path A as
"expected to work, confirm on first install". If activation fails with SIP on, stop there and
decide between Path B and asking Apple; do not work around it by lowering security.

### Path B: Developer ID + notarization (distribution entitlements)

- Needed only if Path A fails with SIP on, or if you want to share the driver.
- Requires Apple to grant the **distribution** forms of `transport.pci` (with a specific
  match for `0x4452`) and `family.scsicontroller`, via
  <https://developer.apple.com/system-extensions/>.
- The request form asks for "your company's hardware vendor ID". Vendor `0x4452` belonged to
  Drobo, Inc., which no longer exists. Nothing I found says whether Apple grants a PCI match
  for a vendor ID the requester does not own; the wording implies they expect ownership. This
  is a request Apple may simply decline. It costs nothing to ask, and an honest framing is
  "interoperability driver for orphaned hardware whose vendor is defunct, personal use".
- If granted: loads on any Mac with SIP on, no device registration, no yearly expiry.

### Path C: no entitlements at all

Loading a dext without the entitlements means disabling SIP, and in practice AMFI boot-args
too (`amfi_get_out_of_my_way=1`, `dk=0x8001`). That is a bigger security reduction than the
kext you are trying to avoid. **Rejected.**

### The existing kext, for comparison

Reduced Security in Recovery plus "allow user management of kernel extensions", then approval
and a reboot. Works today in principle (the arm64e slice exists), but it is exactly what you
ruled out, and a Developer ID kext from a dead vendor will not survive Apple's kext removal.

## `systemextensionsctl developer on`

- What it does: turns off sysextd's location check, so a system extension can be activated
  from an app that is not in `/Applications` (for example straight from Xcode's build
  directory), and relaxes replacement of an already-installed version.
- What it does not do: grant entitlements or bypass signature checks.
- SIP: Apple's doc presents developer mode and SIP as separate switches, but developers report
  the command itself refusing to run until SIP is disabled. Assume it needs SIP off.
- **It is not required.** Without it you copy the built app into `/Applications` before
  activating and bump the dext's version to replace an installed build. That is the workflow
  to use on the Studio.

## Does any path need a security change?

| Path | Reduced Security | SIP change | Kext approval | Other |
|---|---|---|---|---|
| A. Development-signed dext | No | No (confirmed on the Studio) | No | Driver Extension consent prompt in System Settings |
| B. Developer ID dext | No | No | No | Same prompt; needs an Apple grant |
| C. Unentitled dext | No | **Yes**, plus AMFI boot-args | No | Rejected |
| Original kext | **Yes** | No | **Yes** | Rejected |

## Risks

1. **Path A's SIP behaviour** (above). Cheap to test: the scaffold in this repo is enough.
2. **The Drobo must enumerate.** When I checked the Studio during this work (after you said it
   was plugged in), no Thunderbolt device other than the OWC hub and the MacBook was present
   and no PCI device with vendor `0x4452` existed. Until the Drobo appears in System
   Information → Thunderbolt, no driver can attach. Check power/boot state (an 8D takes several
   minutes), and that the cable is a Thunderbolt 3 cable on a Thunderbolt port.
3. **32-bit DMA through the Apple silicon DART.** Expected to work (the kernel allocates bus
   addresses to fit the DMA specification), not yet demonstrated on this device.
4. **Protocol unknowns** listed in section 11 of the protocol notes. Most are resolved by one
   read-only probe run.
5. **Data safety.** The volumes hold real data. Bring-up order should be: probe (no I/O) →
   INQUIRY / READ CAPACITY → read-only block I/O with writes rejected in the driver → writes
   last, and only after the read path has been checked against known file contents. BeyondRAID
   lives in the Drobo's firmware, so the host only sees finished LUNs, but a wrong LBA or
   length in a write would still corrupt a filesystem.
6. **Dashboard.** Drobo Dashboard 3.6.1 is Intel-only and talks to the unit through vendor
   SCSI commands (`0xEA`). The passthrough channel carries them, so Dashboard under Rosetta may
   work, but that is a separate effort. Without it there is no health or capacity UI.

## Recommendation

Go with **Path A**. Sequence:

1. You: register the two App IDs and confirm the Studio is a registered device (10 minutes in
   the portal).
2. Build the scaffold signed for development, install to `/Applications` on the Studio,
   activate. This answers the SIP question with no hardware risk, because the stub does not
   write to the device.
3. Get the Drobo to enumerate on Thunderbolt, then read the stub's log for PCI config and BARs.
4. Implement in the order given under Risks, item 5.
5. In parallel and optionally, file the Path B request with Apple. A grant would remove the
   device-registration and yearly-expiry limits; a refusal costs nothing.

## Sources

- [Requesting Entitlements for DriverKit Development](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)
- [Debugging and testing system extensions](https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions)
- [Creating custom PCIe drivers for Thunderbolt devices](https://developer.apple.com/documentation/pcidriverkit/creating-custom-pcie-drivers-for-thunderbolt-devices)
- [Forum: How to sign a DEXT (DTS)](https://developer.apple.com/forums/thread/809202)
- [Forum: PCIDriverKit entitlements during development (DTS)](https://developer.apple.com/forums/thread/795835)
- [Forum: DriverKit entitlement policy clarification for development purposes (DTS)](https://developer.apple.com/forums/thread/818358)
- [Forum: dext "Exec format error" with SIP enabled on macOS 26.2](https://developer.apple.com/forums/thread/813880)

Forum answers are from an Apple DTS engineer but are not formal documentation.
