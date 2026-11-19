# Feature coverage

What the original Drobo software did, and where this project stands. Status values:
**verified** (seen working on a Drobo 8D), **unverified** (implemented, compiles, not yet run
on hardware), **unsupported** (implemented, but the hardware or firmware refuses it on a stock
unit, so it cannot work for users), **partial**, **no**.

Last updated for driver v0.30.1.

## Against the original kext (`DroboTBT.kext` 1.4)

Every externally visible function of the kext, from its symbol table.

| Kext capability | Kext code | Here | Status |
|---|---|---|---|
| PCI match `4452:3844` (8D) | `Info.plist` | `IOPCIMatch` | verified |
| PCI match `4452:5570` (other Thunderbolt models) | `Info.plist` | second `IOPCIMatch` personality (v0.24.0) | unverified: no such unit has been tried |
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
| Blink lights (identify) | vendor `EA` operation `06` | back in the app with Dashboard's framing since v0.27.0 (protocol notes 11.14) | **disabled**: on hardware the unit stopped responding and restarted, lights never blinked (protocol notes 11.8) |
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
| Per-drive error counters and disk pack state (firmware shell: `state error`, `state dpm`) | vendor `EA` operation `0A` (protocol notes 11.22 to 11.25) | removed from the app (driver v0.30.1 shell plumbing kept, inert) | **unsupported**: verified on hardware (driver 0.30.1) that the 8D turns down the command text at once (SRB response 4). Its firmware accepts shell commands only in the VxWorks ED&R lab/debug state, which a deployed unit is not in and which no host-side change can set (11.24, 11.25). Not in Dashboard's UI: a support hook |
| S.M.A.R.T. attributes (firmware shell: `SmartStatus`) | same | removed from the app | **unsupported**: refused the same way (11.25). The per-drive temperature, error count and life remaining of page `35` are the S.M.A.R.T. data the Drobo does give out, and that path works |
| Power-cycle a bay, wipe a drive's Drobo header, expunge a drive (firmware shell) | same | removed from the app | **unsupported**: refused the same way (11.25), so none has ever reached the shell. Added at the maintainer's request |
| SSD cache ("Accelerator Bay") management | unknown | shown as a bay only | no: needs Dashboard analysis |
| Automatic updates | n/a | update check only (see README) | partial |

## How to close the gaps

- Anything marked "needs Dashboard analysis" starts with reverse-engineering
  `Drobo Dashboard.app` 3.6.1 (Intel-only): find how it issues SCSI commands and enumerate the
  CDBs and pages it sends that are not in the tables above. Record findings as a new section in
  the protocol notes before writing code.
- Anything "unverified" needs a maintainer run on hardware; say exactly what to test in the PR.
- Anything "unsupported" is not a gap to close in this project: the code is written and
  correct, but the firmware refuses it on a stock unit. The firmware-shell Drive tools are the
  only such rows; see protocol notes 11.25 for why (the VxWorks ED&R lab/debug state) and why
  no safe host-side change enables them. The app's Drive tools UI and the `drobo console`
  command were removed in v0.30.1; the driver keeps the shell plumbing but nothing drives it.

## Dashboard data: what the driver already publishes

Checked against what a fuller third-party Drobo dashboard shows, to decide what the app can
display without new protocol work. "Polled" means the driver already reads the page (sub-pages
`01 02 03 05 06 08 09 30 31` of MODE SENSE page `0x3A`, protocol notes 11.5 and 11.6) and
publishes its raw bytes under `DroboHealth`.

| Dashboard feature | Source | Status |
|---|---|---|
| Array status, alerts ("notifications") | Status page `09` flags | shown (Summary) |
| Relayout / rebuild count | Status page `09` | shown (Summary) |
| Protected capacity, used, free | Capacity page `02` | shown (Summary) |
| Unprotected capacity | Capacity page `02`, fourth u64 | decoded; shown when non-zero |
| Capacity alert thresholds | Options page `30`, first two bytes (85 and 95 observed) | decoded; shown (Summary) |
| Per-bay light, size, model | Slot page `03` | shown (Summary, Drives) |
| Per-drive interface | Slot page `03`, last 8 bytes of the identity field | decoded; shown (Drives) |
| Per-drive managed capacity | Slot page `03`, second u64 of the record | decoded; shown (Drives) |
| Per-drive "short identity" and trailing u32 | Slot page `03` | settled: a repeat of the model's first 16 bytes, and zero (protocol notes 11.9) |
| Per-drive error count, firmware revision, serial, rotation speed, SSD or hard disk, life remaining | Slot page 2, sub-page `35` (protocol notes 11.9, 11.12) | **verified** on the 8D with v0.25.0; opt-in (Advanced → Read drive and system details), shown on Drives |
| Per-drive temperature | same page | the 8D reports 0 for every drive (11.12); shown only if a unit reports it |
| Per-drive disk state | same page | in diagnostics only; encoding unknown |
| Name, serial | Settings page `05`, `DroboStatus` | shown |
| Firmware version, build date, platform | Firmware page `08` | version and build shown; platform decoded only |
| Device clock | Settings page `05` (UTC u32, offset u16) | polled, not decoded |
| Slot count, max LUNs, max LUN size | Config page `01` | polled; only the slot count is used |
| Protocol version | Protocol page `06` | polled, not decoded |
| Dual disk redundancy, spin-down | Options page `31` | shown (Summary), editable (Advanced) |
| Identify | Blink, system operation `06` | **verified** on the 8D with v0.27.1 (Drives, Advanced). Blinks for a long time; no stop or timed form yet |
| Restart | system operation `03` | in the app (Advanced) since v0.27.0; unverified |
| LED brightness | system operations `18` / `21`, level 0 to 9 (protocol notes 11.15) | in the app (Advanced → Settings) since v0.28.0; unverified |
| SSD (hot data) cache | no command found; Dashboard only shows a status | Summary shows whether the SSD bay holds a healthy drive |
| Open in Finder | no protocol needed | in the app (Volumes) |
| Drobo-style Finder volume icon with a fullness bar | a `.VolumeIcon.icns` written to the volume | in the app (Volumes → Set Icon), writable volumes only; checked on a disk image, not on a Drobo |
| Request throughput and latency | the driver's own counters in `DroboStatus` | shown (Advanced), live only, no history |
| Enclosure temperature, uptime | system info, sub-page `33` (protocol notes 11.11, 11.13) | **verified** on the 8D with v0.26.0 (uptime in seconds, temperature in °C); opt-in, shown on Summary |
| Fan levels and health, power supply health | sub-pages `37`, `36` | **the 8D refuses both** (11.13); the driver drops them and carries on. Shown only on a unit that answers |
| The Drobo's own IOPS and throughput | sub-page `34` | answered by the 8D; in diagnostics only, units unknown |
| Disk pack status | sub-page `11`; layout not decoded | **not polled**, backlog item 13 |
| Hot data cache, data integrity | no page identified | **unknown** |
| Events log | the Drobo's own log: no reference | **unknown**. The Events tab instead records changes the app sees between polls (alerts, drive states, restarts, mounts) |
| Scans | same | **unknown** |
| Performance history | sampled by the app from the counters above | shown (Performance): last hour per poll, last 24 hours per minute, in memory only |
| Several Drobos in one window | app reads the first controller only | not implemented, backlog item 11 |

Nothing in the "unknown" rows is guessed into code. Each needs a reference (Drobo Dashboard's own
requests, or a field observed on hardware and recorded in protocol notes section 11) before it is
decoded.

## Distribution packaging

| Feature | Status |
| --- | --- |
| arm64 app and DMG packaging | implemented; unsigned preview built and DMG checksum verified |
| Distribution profile validation and PCI scope reduction | implemented; 19 automated validation tests pass; rejects a real device-limited development profile |
| Developer ID signing, notarization and stapling | implemented, unverified end to end; Apple distribution approval pending |
| Driver activation from a public download on an unregistered Mac | unverified; requires approved distribution profiles and hardware |
