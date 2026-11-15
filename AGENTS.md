# AGENTS.md

Guide for AI agents (and people) contributing to this repository. Read this first, then
`docs/01-protocol-reverse-engineering.md`, which is the source of truth for the wire protocol.

## What this is

A DriverKit driver extension plus a small host app that make the Drobo 8D Thunderbolt array
work on Apple silicon Macs without a kext. Layout:

| Path | What |
|---|---|
| `DroboDriver/` | The dext. `DroboSCSIController.*` is the SCSI controller; `DroboUserClient.*` is the app's command channel; `DroboProtocol.h` holds every wire structure and constant |
| `DroboHost/` | SwiftUI host app. `DroboHostApp.swift` is UI, `DroboMonitor.swift` decodes what the driver publishes and sends commands, `AppServices.swift` is updates, login item, notifications |
| `docs/01-…` | Protocol notes. Sections 1–10 are static analysis of the original kext; section 11 is what was observed on real hardware; section 12 lists open questions |
| `docs/02-…` | Signing and entitlement paths |
| `docs/03-coverage.md` | Feature coverage against the original driver and Dashboard, with verification status |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and not committed |

## Build and check

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project DroboDriverKit.xcodeproj -scheme DroboHost -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

That unsigned build is the CI check and the only thing you can run without the hardware. There
are no unit tests yet (adding host-side tests for the page decoders in `DroboMonitor.swift` is
a good first PR).

## You almost certainly do not have the hardware

Nothing here can be tested end to end without a Drobo 8D, a development-signed build and the
owner pressing Activate. So:

- **Say what you verified.** A PR that only compiles must say "compiles; not run on hardware".
  Never write that something works on the device unless a maintainer ran it and told you.
- **Update `docs/03-coverage.md`** when you add or change a feature: its status column
  distinguishes "verified on hardware", "implemented, unverified" and "not implemented".
- **Ground protocol changes in evidence**: a kext function and offset, a drobo-utils reference,
  or a hardware observation recorded in section 11. Do not guess field meanings into code.
- If you need the original kext for analysis, the maintainer has it locally in `reference/`
  (git-ignored). It is Drobo's proprietary binary: **never commit it or paste large parts of
  its disassembly.** Describing what it does, with function names and offsets, is fine.

## Safety rules (the driver talks to hardware holding someone's data)

1. Writes stay **off by default** and opt-in per LUN. Do not change that default.
2. Every MMIO write and every new command sent to the device must be listed in the header
   comment of `DroboSCSIController.cpp`.
3. Never complete a SCSI task from a response whose slot index and transaction ID do not both
   match (see `ProcessCompletions`).
4. Destructive Drobo management commands (format, reset, LUN create/delete, firmware update)
   are **out of scope** unless an issue explicitly asks for one and the maintainer agrees.
5. Read the device's self-describing interrupt tables and compare against the constants before
   using a doorbell, as bring-up does now. If they differ, disable the feature, do not adapt.
6. Keep failure modes safe: on a timeout, disable the feature (as health polling and flush
   forwarding do) or mark the controller dead. Never retry writes blindly.

## DriverKit rules learned the hard way

All of these cost a driver version; details in protocol notes 11.3 and 11.6.

- `UserGetDMASpecification` must return `kDMAOutputSegmentHost64`.
- The dext must create and register a queue named `AuxiliaryQueue`, and call
  `UserReportHBAConstraints` with all required keys from `UserInitializeController`.
- Never call `UserCreateTargetForID` from the queue that serves SCSI tasks.
- All device state lives on the one serial I/O queue (`DroboIO`). Do not add locks; dispatch.
- `Stop` must not block on that queue, must cancel every queue and dispatch source, and has a
  watchdog. If you add a queue or source, add it to the cancel list in `Stop`.
- The dext's `os_log` output has not been visible in `log show`. Publish state with
  `SetProperties` (`DroboStatus`, `DroboHealth`) and read it with `ioreg`.
- Each `IOPCIDevice::MemoryRead32` is a kernel round trip; use the mapped BAR helpers
  (`Reg32`, `Port32`).
- The driver is arm64 only. Never add an arm64e slice.

## Conventions

- C++ in the dext: 4 spaces, same brace and naming style as the existing files, comments that
  explain why (especially anything protocol-related), no exceptions or RTTI.
- Swift in the app: no third-party dependencies.
- Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` for any driver
  change; macOS will not replace an installed extension with the same version.
- One logical change per PR. Fill in the PR template, including the verification section.
- Do not add personal data to the repo: serial numbers, device UDIDs, volume names, IP
  addresses.

## Where to start

Open issues are the backlog; ones labelled `good first issue` need no hardware. Anything
labelled `needs hardware` will be tested by the maintainer after review.
