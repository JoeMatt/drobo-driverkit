# Feature coverage

What the original Drobo software did, and where this project stands. Status values:
**verified** (seen working on a Drobo 8D), **unverified** (implemented, compiles, not yet run
on hardware), **partial**, **no**.

Last updated for driver v0.23.0.

## Against the original kext (`DroboTBT.kext` 1.4)

Every externally visible function of the kext, from its symbol table.

| Kext capability | Kext code | Here | Status |
|---|---|---|---|
| PCI match `4452:3844` (8D) | `Info.plist` | `IOPCIMatch` | verified |
| PCI match `4452:5570` (other Thunderbolt models) | `Info.plist` | not matched | no |
| BAR mapping, bus master, MSI | `InitializeController`, `CreateDeviceInterrupt` | `BringUp`, `Start` | verified |
| HOST_BAR_READY handshake | `TriggerHostBarInterrupt` | `HostBarReady` | verified |
| DroboPort parsing, capabilities, LUN table | `Channel::init` | `BringUp` | verified |
| Self-describing doorbell tables | `SCSIChannel::init`, `ApplyOperator` | constants checked against the tables | verified (no general interpreter) |
| Connect / retry until adapter ready | `Connect`, timers | `BringUp` loop | verified |
| Serial-number check on reconnect | `IsSerialNumberMatch` | not implemented | no |
| Block reads (READ 6/10/12/16) | `SCSIChannel::BuildDroboRequest` | `QueueIO` | verified |
| Block writes (WRITE 6/10/12/16) | same | `QueueIO`, opt-in per LUN | unverified |
| VERIFY 10 | routed to block channel | rejected | no |
| Splitting I/O larger than max transfer | `QueueRequest` | not needed: transfers capped at 512 KiB | n/a |
| Multi-entry scatter/gather lists | `BuildDroboRequest` | single entry (the kernel supplies one bus address) | verified |
| Bounce buffers | `InitializeMemoryBuffers`, `CopyData` | not needed | n/a |
| Burst submission, concurrent requests | `ProcessRequests` | `Pump` (32 slots, window-1 per doorbell) | verified |
| Completion from interrupt | `HandleInterruptRequest`, `ProcessCompleteRequests` | `HandleInterrupt`, `ProcessCompletions` | verified |
| Response format for interface < 4 | `ProcessCompleteRequests` | not implemented (driver refuses interface < 4) | no |
| INQUIRY, REPORT LUNS, READ CAPACITY 10/16, TEST UNIT READY | `InDriverChannel` | `HandleTask` | verified |
| MODE SENSE 6/10 from the host | passthrough to device | answered in driver (write-protect bit only) | partial |
| Passthrough of arbitrary CDBs (incl. vendor `0xEA`) from the SCSI layer | `TMChannel` | driver-originated management requests only | partial |
| SYNCHRONIZE CACHE | `SysControlChannel` (command 5) | `QueueFlush` | unverified |
| WRITE BUFFER | `SysControlChannel` (command 5) | rejected | no |
| START STOP UNIT | `SysControlChannel` (command 3) | answered GOOD, not forwarded | no |
| Sleep / wake | `setPowerState`, `HostSleepEvent`, `HostWokeUp` | `SetPowerState`, `WakeDevice` | unverified |
| Surprise removal | `0xFFFFFFFF` checks, `phaseOneRemoval`… | `FailAllSlots`, `Stop` | partial (unplug works; not stress-tested) |
| Shutdown / restart notification | `systemWillShutdown` | not implemented | no |
| Task management (abort, resets) | empty stubs | stubs | same as kext |
| Request timeout | `HandleTimeout` | 30 s, then controller marked dead | unverified |
| Trace facility | `com_drobo_IOTrace` | registry properties instead | n/a |

## Against Drobo Dashboard

Dashboard itself has **not** been reverse-engineered. The list below is its feature set as
users knew it, mapped to the management protocol documented by drobo-utils. Features with no
protocol reference are marked as needing that analysis.

| Dashboard feature | Protocol | Here | Status |
|---|---|---|---|
| Status and alerts | MODE SENSE `3A/09` | dashboard, menu bar, notifications | verified |
| Rebuild progress | `3A/09` relayout count | blocks left + estimate | verified (estimate is rough) |
| Capacity (used / free) | `3A/02` | overview | verified |
| Drive bays: size, model, state | `3A/03` | bays card, incl. mSATA cache drive | verified |
| Device name, firmware version | `3A/05`, `3A/08` | header | verified |
| Dual disk redundancy, spin-down (read) | `3A/31` | overview | verified |
| Dual disk redundancy, spin-down (change) | MODE SELECT `7A/31` | Settings sheet | unverified |
| Capacity alert thresholds (read) | `3A/30` | read, not shown | partial |
| Capacity alert thresholds (change) | MODE SELECT `7A/30` | not implemented | no |
| Rename the Drobo, set its clock | MODE SELECT `7A/05` | Rename | unverified |
| Blink lights (identify) | vendor `EA` command `06` | Blink Lights | unverified |
| Shut down / standby | vendor `EA` command `0D` | Shut Down | unverified |
| Restart | unknown | not implemented | no: needs Dashboard analysis |
| Volume list, mount, unmount, eject | host side | volumes card | verified (list, eject), unverified (per-volume buttons) |
| Create / delete / resize volumes | drobo-utils has `SetLunSize` only | not implemented | no: needs Dashboard analysis |
| Format a volume | host side | Disk Utility, once writing is on | n/a |
| Dim lights / LED brightness | unknown | not implemented | no: needs Dashboard analysis |
| Email alerts | host side | local notifications only | partial |
| Firmware update | drobo-utils documents it for older units | not implemented, by decision | no |
| Reset / erase the Drobo | unknown | not implemented, by decision | no |
| Diagnostics download | drobo-utils `GetDiagRecord` | not implemented | no |
| SSD cache ("Accelerator Bay") management | unknown | shown as a bay only | no: needs Dashboard analysis |
| Automatic updates | n/a | update check only (see README) | partial |

## How to close the gaps

- Anything marked "needs Dashboard analysis" starts with reverse-engineering
  `Drobo Dashboard.app` 3.6.1 (Intel-only): find how it issues SCSI commands and enumerate the
  CDBs and pages it sends that are not in the tables above. Record findings as a new section in
  the protocol notes before writing code.
- Anything "unverified" needs a maintainer run on hardware; say exactly what to test in the PR.
