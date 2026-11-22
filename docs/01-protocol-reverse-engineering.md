# Drobo 8D Thunderbolt host protocol — reverse-engineering notes

Source: `DroboTBT.kext` 1.4 [115880] (`com.drobo.SCSI.ThunderBolt`, Team 7L83S9698G, built Feb 2021,
Xcode 9.4.1 / macOS 10.13 SDK), copied from `/Library/Extensions` on the Mac Studio.
Universal x86_64 + arm64e.kernel. The binary is **not stripped**: all C++ symbols and several
hundred log format strings are present.

Method: static only. `llvm-objdump` disassembly of both slices, annotated with the `__cstring`
contents and vtable layouts. The x86_64 slice was read as the primary text (no PAC noise); the
arm64e slice has the same symbol set (871 vs 843 symbols) and was used as a cross-check. Nothing
was executed and no hardware was probed. Offsets below are x86_64 function addresses.

Confidence markers used below:

- **[obs]** read directly from the code or strings.
- **[inf]** inferred from how a field is used or from a log string naming it.
- **[unk]** not determined; needs the hardware.

## 1. What kind of device this is

- PCIe endpoint behind the Drobo's Thunderbolt controller. Matches `IOPCIDevice` with
  `IOPCIMatch 0x38444452`: vendor `0x4452` ("DR"), device `0x3844` ("8D"). A second personality
  matches `0x55704452` (device `0x5570`, "Up"), presumably the other Thunderbolt Drobos; same
  driver class. **[obs]**
- Both personalities set `IOPCITunnelCompatible` and `IOPCIPauseCompatible`. **[obs]**
- The host driver is an `IOSCSIParallelInterfaceController` subclass, but the wire protocol is
  **not** a standard HBA (no AHCI/NVMe/MPT). It is a Drobo-specific message protocol:
  the host builds small request structures in its own RAM, hands their bus addresses to the
  Drobo through a shared-memory queue in BAR1, rings a doorbell, and the Drobo (acting as PCIe
  bus master) DMAs the request and the data to/from host memory. **[obs]**
- Read/write commands are **not** passed through as CDBs. The host parses the CDB and sends
  `{opcode, LUN, LBA, block count, scatter/gather list}`. Other commands are either answered
  inside the host driver or passed as a raw 16-byte CDB on a side channel. **[obs]**
- BAR0 register offsets (`0x21878`) are consistent with the Drobo's SoC exposing its
  internal-register window as BAR0, with doorbell registers in it. **[inf]**

## 2. Driver object model (for orientation)

| Class | Role |
|---|---|
| `com_drobo_SCSI_ThunderBoltController` | The `IOSCSIParallelInterfaceController`. Owns the PCI device, BAR mappings, interrupt source, a pool of `IODMACommand`s, and four channels. |
| `com_drobo_Channel` | Base channel: capability snapshot, LUN table pointer, request queue (`com_drobo_AtomicQueue`), two work loops (requests / responses). |
| `com_drobo_SCSIChannel` | The block I/O channel and the base for the two below. Owns the interrupt table, doorbell helpers, request building and completion. |
| `com_drobo_TMChannel` | "Transport Manager" channel: raw CDB passthrough. |
| `com_drobo_SysControlChannel` | System-control channel (SYNCHRONIZE CACHE, WRITE BUFFER). |
| `com_drobo_InDriverChannel` | No hardware I/O. Answers TEST UNIT READY, REPORT LUNS, READ CAPACITY etc. from cached data. |
| `com_drobo_AtomicQueue` | Lock-free slot allocator with per-slot states (free / locked / available / processing / processed / completing). |

Command routing, `GetRequestType()` @ `0x302c` + jump table in `ProcessParallelTask()` @ `0x2dc6` **[obs]**:

| Type | Channel | CDB opcodes |
|---|---|---|
| 1 | SCSI (block I/O) | READ 10/12/16 (`28`,`A8`,`88`), WRITE 10/12/16 (`2A`,`AA`,`8A`), VERIFY 10 (`2F`) |
| 2 | SysControl | SYNCHRONIZE CACHE (`35`), WRITE BUFFER (`3B`) |
| 3 | TM (passthrough) | INQUIRY (`12`), MODE SENSE 6/10, MODE SELECT 6/10, `EA` ("SCSIOP_DATA_ROBOTICS_OPERATION", the Drobo Dashboard vendor command), and every opcode not listed elsewhere |
| 4 | In-driver | TEST UNIT READY (`00`), START STOP UNIT, PREVENT ALLOW MEDIUM REMOVAL, READ CAPACITY 10 (`25`), SERVICE ACTION IN (`9E`, READ CAPACITY 16), REPORT LUNS (`A0`) |

CDBs longer than 16 bytes are rejected.

## 3. PCI resources

`InitializeController()` @ `0xd8c` **[obs]**:

1. Enables bus mastering and memory space, disables I/O space.
2. Maps device memory index 0 and index 1 (`mapDeviceMemoryWithIndex`). The strings call these
   BAR0 and BAR1. Whether they are literally config-space BAR0/BAR1 or the first two memory
   ranges of 64-bit BARs is **[unk]**; the scaffold driver logs `GetBARInfo` for all six BARs to
   settle it.
3. BAR0 → "interrupts address" (register window). BAR1 → `DroboPort` shared-memory region
   (must be 8-byte aligned).
4. Interrupt: walks the interrupt list for the first entry with `kIOInterruptTypePCIMessaged`
   (MSI) and builds an `IOFilterInterruptEventSource` on it (`CreateDeviceInterrupt()` @ `0x2cba`).
5. DMA: every `IODMACommand` in the driver is created with
   `OutputLittle32`, **32 address bits**, max segment `0x80000` (512 KiB), max transfer
   `0x100000` (1 MiB), alignment 1, using the device's IOMapper. So all bus addresses given to
   the Drobo must fit in 32 bits.
6. Registers 3 power states.

## 4. BAR0: hard-coded register

Only one BAR0 offset is hard-coded; everything else comes from the interrupt table (section 6).

| Offset | Name (from strings) | Use |
|---|---|---|
| `0x21878` | `INCOMING_DOORBELL_CAUSE_REG` | Bit 21 (`0x00200000`) = `HOST_BAR_READY`. |

`TriggerHostBarInterrupt(n)` @ `0x12fc` **[obs]**: `BAR0[0x21878] |= 0x200000`, then poll up to
`2n` times, 500 ms apart, until the Drobo clears bit 21 ("BAR remap completed"). A read of
`0xFFFFFFFF` anywhere is treated as surprise removal. Called with `n=5` at controller init and
`n=60` from `SCSIChannel::Connect()`.

Meaning **[inf]**: the host tells the Drobo firmware that the host has assigned/mapped the BARs,
and the firmware then (re)maps its side and publishes the `DroboPort` structure into BAR1.

## 5. BAR1: the `DroboPort` structure

All fields little-endian. Offsets inside it are **byte offsets relative to the start of BAR1**.

| Offset | Type | Field | Evidence |
|---|---|---|---|
| `0x00` | char[16] | Signature, ASCII `"DroboPort"` NUL-padded. Checked with a 16-byte compare; first byte `0x44` is tested first. | `IsDroboPortReady()` @ `0x5d68` **[obs]** |
| `0x18` | u32 | Offset of **LUN table** | `Channel::init()` @ `0x42ce` **[obs]** |
| `0x1C` | u32 | Offset of **capabilities** | same **[obs]** |
| `0x20` | u32 | Offset of SCSI channel **request list** | `SCSIChannel::init()` @ `0x4d96` **[obs]** |
| `0x24` | u32 | Offset of SCSI channel **response list** | same **[obs]** |
| `0x28` | u32 | Offset of SysControl request list | `SysControlChannel::init()` **[obs]** |
| `0x2C` | u32 | Offset of SysControl response list | same **[obs]** |
| `0x30` | u32 | Offset of TM request list | `TMChannel::init()` @ `0xb0a6` **[obs]** |
| `0x34` | u32 | Offset of TM response list | same **[obs]** |
| `0x38` | u32 | Offset of **inbound interrupt table** (host → Drobo doorbells) | `SCSIChannel::init()` **[obs]** |
| `0x3C` | u32 | Offset of **outbound interrupt table** (Drobo → host) | same **[obs]** |
| `0x40` | u32 | Offset of serial-number string (32 bytes compared), or `0xFFFFFFFF` if absent | `IsSerialNumberMatch()` @ `0x5dbc` **[obs]** |

`0x10`–`0x17` are not read by this driver **[unk]**.

### 5.1 Capabilities (at `DroboPort[0x1C]`)

Field names are taken verbatim from the `DumpCapabilities()` format string @ `0x473a` **[obs]**.

| Offset | Field | Notes |
|---|---|---|
| `0x00` | Interface Version | Behaviour switches at `>= 3` (summary interrupt) and `>= 4` (wide response entries). |
| `0x04` | Transfer Mode | |
| `0x08` | Max Transfer Size | Bytes per request. Larger I/O is split in two. |
| `0x0C` | Max Outstanding Transactions | Reported task count is half of this. |
| `0x10` | Max LUNs | |
| `0x14` | Drobo Port Flags | |
| `0x18` | Max Burst Size | |
| `0x1C` | Stall Size | |
| `0x20` | Max SGL Entries | |
| `0x24` | Host Interface Version | **Written by the host**: the driver stores `1` here before reading the rest. |
| `0x28`–`0x3F` | 6 more u32 | Copied but not named **[unk]**. |

### 5.2 LUN table (at `DroboPort[0x18]`)

Array of 16-byte entries, one per LUN, `Max LUNs` long (32 assumed before init) **[obs]**:

| Offset | Type | Field |
|---|---|---|
| `0x00` | u32 | Non-zero = LUN present. Probably the block size **[inf]**; block I/O uses a fixed 512-byte shift. |
| `0x08` | u64 | Bound for LBA range checks: a request is rejected unless `lba + blocks - 1 < value`. So this is the LUN's block count **[inf]**. |

The in-driver channel serves READ CAPACITY and REPORT LUNS from this table.

## 6. Self-describing interrupt/doorbell tables

The Drobo does not use fixed doorbell registers. BAR1 carries two tables that tell the host
*which BAR0 register to touch, with what value, and with what operator* for each event. A
DriverKit port must implement this interpreter rather than hard-code registers.

Table layout **[obs]** (`SCSIChannel::init()`):

- 9 × u32 header, then N × `PcieInterruptDefEntry` (0x54 bytes, 21 × u32).
- Inbound table (`DroboPort[0x38]`): 7 entries. Outbound table (`DroboPort[0x3C]`): 6 entries.
- The outbound header doubles as the global endpoint-interrupt enable/disable descriptor:
  `hdr[1]`=enable register offset, `hdr[3]`=value, `hdr[4]`=operator;
  `hdr[5]`=disable register offset, `hdr[7]`=value, `hdr[8]`=operator.

`PcieInterruptDefEntry` is five `{offset, size, value, operator}` groups after one leading u32
**[obs]** (group order from which accessor reads which offsets):

| Entry offset | Group | Used by |
|---|---|---|
| `0x00` | (unknown leading word) | not read **[unk]** |
| `0x04` / `0x08` / `0x0C` / `0x10` | **trigger**: reg offset, size, value, operator | `TriggerInterrupt()` @ `0x61f6` |
| `0x14` / `0x18` / `0x1C` / `0x20` | **state**: reg offset, size, mask, operator | `GetInterruptState()` @ `0x60fa` |
| `0x24` / `0x28` / `0x2C` / `0x30` | **enable** | `EnableInterrupt()` @ `0x629a` |
| `0x34` / `0x38` / `0x3C` / `0x40` | **disable** | `DisableInterrupt()` @ `0x62ec` |
| `0x44` / `0x48` / `0x4C` / `0x50` | **clear** | `ClearInterrupt()` @ `0x6248` |

Register offsets are relative to BAR0. Operators, `ApplyOperator()` @ `0x633e`, jump table at
`0x646c` **[obs]**:

| Op | Action on the 32-bit register |
|---|---|
| 0 | `reg &= value` |
| 1 | `reg |= value` |
| 2 | `reg ^= value` |
| 3 | `reg = value` |
| 4 | no write |

Every operator ends by re-reading the register and returning it. `GetInterruptState` instead
reads the register into a local and applies the operator to the local copy (so "state" is
`reg & mask` without modifying hardware).

Which entry means what **[obs]** for the index, **[inf]** for the name:

| Table / index | Meaning | Used by |
|---|---|---|
| In[0] | SCSI request ready (`DRIVER_DATA_PACKET_READY`). Also polled: state == 0 means the Drobo consumed the last burst. | `SCSIChannel::SetRequestReady` / `IsReadyToReceive` |
| In[3] | SysControl request ready | `SysControlChannel` |
| In[4] | TM request ready | `TMChannel` |
| In[5] | Driver ready / driver-init. State == 0 means "driver init processed". | `SetDriverReady` @ `0x66f6`, `IsDriverInitProcessed` |
| In[1], In[2], In[6] | not referenced **[unk]** |
| Out[0] | SCSI response ready | `SCSIChannel::IsResponseReady` / `SetResponseCompleted` |
| Out[1] | TM response ready | `TMChannel` |
| Out[2] | SysControl response ready | `SysControlChannel` |
| Out[4] | Adapter ready (state != 0) | `IsAdapterReady()` @ `0x53f6` |
| Out[5] | Summary/cause interrupt, only when Interface Version >= 3 | `ClearInterruptCause()` @ `0x8e42` |
| Out[3] | not referenced **[unk]** |

"Response ready" is `state != 0 && state != 0xFFFFFFFF`.

## 7. Bring-up sequence

Reconstructed from `InitializeController`, `InitializeDroboChannels` @ `0x140e`,
`SCSIChannel::init`, `Connect` @ `0x5558`, `StartController` @ `0x29b4` **[obs]**:

1. Map BAR0 and BAR1; enable memory + bus master.
2. `TriggerHostBarInterrupt(5)`. If bit 21 does not clear within ~5 s, start a retry timer and
   try again later (the firmware may still be booting; a Drobo takes minutes).
3. Read `BAR0[0x21878]`; require not `0xFFFFFFFF` and bit 21 clear. Require the `"DroboPort"`
   signature in BAR1.
4. Create channels in order: in-driver, TM, SysControl, SCSI. Each reads capabilities and the
   LUN table and writes Host Interface Version = 1. The SCSI channel also copies both interrupt
   tables into RAM and reads its max burst size from the first u32 of its request list.
5. `SetDriverReady()`: trigger In[5].
6. `Connect()`: require adapter ready (Out[4] state != 0), signature, and matching serial
   number. Allocate bounce buffers. `ClearAndEnableInterrupts(true)`, `EnableEndpointInterrupts()`.
   `TriggerHostBarInterrupt(60)`. Re-check signature/serial. Create SCSI target 0.
   If the adapter is not ready, a connect timer retries.
7. `StartController()`: enable the MSI event source.

`ClearAndEnableInterrupts` @ `0x8c22`: clear Out[5] (v3+), clear Out[0..2], then enable Out[5]
if v3+, otherwise enable Out[0], Out[1], Out[2] individually.

Target model: one target (ID 0), LUNs `0..MaxLUNs-1`, initiator-managed (`DoesHBAPerformDeviceManagement`
creates the target itself). Task-management requests (abort, LUN reset, target reset) are
stubs that return immediately.

Sleep/wake: `HostSleepEvent` waits for in-flight I/O to drain; `HostWokeUp` polls every 200 ms
for the firmware BAR remap, i.e. the host-BAR-ready handshake is repeated after wake.

## 8. Request submission

### 8.1 Request list (in BAR1, per channel)

| Offset | Type | Field |
|---|---|---|
| `0x00` | u32 | Window / max burst size (read by host) |
| `0x04` | u32 | Number of entries in this burst (written by host) |
| `0x08` + 16·i | `QueueEntry` | See below |

`QueueEntry` (16 bytes) **[obs]**, written in `ProcessRequests()` @ `0x7a06`:

| Offset | Type | Field |
|---|---|---|
| `0x00` | u32 | Request bus address, low 32 bits |
| `0x04` | u32 | Request bus address, high 32 bits (always 0 given the 32-bit DMA spec) |
| `0x08` | u32 | Request length in bytes (header + SGL) |
| `0x0C` | u32 | Transaction ID |

Flow: wait for `IsReadyToReceive()` (In[0] state == 0) → fill up to `burst-1` entries, bounded
by Max Outstanding Transactions → write the count to `+0x04` → trigger In[0]. Transaction IDs
are a per-channel incrementing 32-bit counter and must be submitted in order.

### 8.2 Block I/O request (`DroboSCSISrbExtension`, 0x2080 bytes)

The request lives in host memory (the kext uses the per-task HBA data area, 0x4100 bytes =
two requests, because an I/O larger than Max Transfer Size is split into two). The Drobo reads
it by DMA. `BuildDroboRequest()` @ `0x6d9a` **[obs]**:

| Offset | Type | Field |
|---|---|---|
| `0x00` | u64 | Bus address of the HBA data area (low 32 bits used) |
| `0x08` | u32 | Host queue slot index (set at submit; `0xFFFFFFFF` until then) |
| `0x0C` | u32 | Transaction ID copy |
| `0x10` | u64 | Host cookie (the `SCSIParallelTask` pointer). Opaque to the device. |
| `0x18` | u32 | Total request length = `0x80 + 16 × SGL entries` |
| `0x1C` | u32 | Request kind: `1` = block I/O |
| `0x20`–`0x2F` | | not written by the host **[unk]** |
| `0x30` | u32 | Operation: `0x00400030` no data, `0x00400031` write (host → Drobo), `0x00400032` read (Drobo → host) |
| `0x34` | u32 | Transfer length in bytes |
| `0x38` | u64 | Host virtual address of the SGL (`request + 0x80`). A host pointer; presumably ignored by the device **[inf]** |
| `0x40` | u32 | LUN |
| `0x48` | u32 | Block count (from the CDB) |
| `0x50` | u64 | Starting LBA (CDB LBA + `offset >> 9` for the second half of a split) |
| `0x60` | u64 | Transaction ID |
| `0x6C` | u32 | **Response:** bytes transferred (interface < 4) |
| `0x74` | u32 | **Response:** SRB response code (interface < 4) |
| `0x78` | u32 | **Response:** SCSI status (interface < 4) |
| `0x80` + 16·i | SGL entry | `{u64 bus address, u32 length, u32 unused}`; up to 512 entries; terminated by an entry whose length is 0 |

CDB decoding **[obs]**: 6-byte (21-bit LBA, 8/16-bit count), 10-byte, 12-byte and 16-byte forms
are handled; LBA/length are byte-swapped from the CDB. Block size is fixed at 512 for the
split-offset arithmetic.

Data buffers **[obs]**: the kext first tries to describe the caller's memory directly
(`gen32IOVMSegments`). If that fails it falls back to pre-allocated contiguous bounce buffers
below 4 GiB and copies. Either way the Drobo sees 32-bit bus addresses.

### 8.3 Passthrough request (`TransportManagerSrbExtension`, 0x2058 bytes)

`TMChannel::BuildDroboRequest()` @ `0xb338` **[obs]**. Same first 0x20 bytes as above, then:

| Offset | Type | Field |
|---|---|---|
| `0x18` | u32 | Total length = `0x58 + 16 × SGL entries` |
| `0x1C` | u32 | Request kind: `3` |
| `0x20` | u32 | Flags: `0x00410020` data-in or no data, `0x00420020` data-out |
| `0x24` | u32 | Transfer length, clamped to Max Transfer Size |
| `0x28` | u64 | Host virtual address of the SGL (`request + 0x58`) |
| `0x30` | u8[16] | CDB |
| `0x40` | u32 | **Response:** bytes transferred |
| `0x4C` | u32 | **Response:** SRB response code |
| `0x50` | u32 | **Response:** SCSI status |
| `0x58` + 16·i | SGL entry | as above |

The SysControl channel reuses this builder with its own request/response lists and doorbells.
Its exact flag values were not decoded **[unk]**.

Structure sizes printed by the kext itself **[obs]**: `BaseSrbExtension` 0x20,
`TransportManagerSrbExtension` 0x2058, `DroboSCSISrbExtension` 0x2080,
`DroboTransportManagerResponse` 0x18, `DroboTransportManagerRequest` 0x20,
`DroboSCSIResponse` 0x18, `DroboSCSIRequest` 0x38, `QueueEntry` 0x10, `ResponseListMMIO` 0x108.

## 9. Completion

Interrupt path **[obs]**: the filter routine (`FilterInterruptRequest` @ `0x3438`) calls
`ClearInterruptCause()` and schedules the handler. The handler (`HandleInterruptRequest` @
`0x3462`) polls `IsResponseReady()` on the SCSI, TM and SysControl channels and kicks each
channel's response work loop.

Response list (`ResponseListMMIO`, 0x108 bytes, in BAR1) **[obs]**,
`ProcessCompleteRequests()` @ `0x7fae`:

| Offset | Type | Field |
|---|---|---|
| `0x04` | u32 | Number of responses in this burst. `0xFFFFFFFF` = device gone. Must be ≤ the request window. |
| `0x08` … | entries | Format depends on Interface Version |

Interface Version < 4, 8-byte entries:

| Offset | Type | Field |
|---|---|---|
| `0x00` | u32 | Host queue slot index (echo of request `+0x08`) |
| `0x04` | u32 | Transaction ID |

Status is then read back from the request structure itself (offsets `0x6C/0x74/0x78`, or
`0x40/0x4C/0x50` for passthrough), which the Drobo has updated by DMA.

Interface Version >= 4, 32-byte entries:

| Offset | Type | Field |
|---|---|---|
| `0x00` | u32 | Host queue slot index |
| `0x04` | u32 | Transaction ID |
| `0x08` | u64 | Bytes transferred |
| `0x10` | u32 | unknown **[unk]** |
| `0x14` | u32 | SRB response code |
| `0x18` | u32 | SCSI status |
| `0x1C` | u32 | unknown **[unk]** |

SRB response codes **[obs]**: `1` = success. `0x12` is also accepted as success (treated as a
short transfer **[inf]**). Anything else fails the task. A transaction ID that does not match
the slot's is logged as "timed-out or was aborted" and dropped.

After draining a burst the host calls `SetResponseCompleted()` (clear Out[n]), which hands the
response list back to the Drobo.

Sense data: there is no sense buffer in the response. The kext synthesises fixed sense blobs
(`gSense_BadLUN`, `gSense_InvalidCDBField`, `gSense_InvalidCommand`) for the in-driver channel
only. Auto-sense from the device was not observed **[inf]**.

## 10. Reset and error handling

- There is **no controller reset register** in this driver. Recovery is: fail all queued
  requests (`FailAllRequests`), disable + clear interrupts, and repeat the host-BAR-ready
  handshake.
- Surprise removal is detected by any MMIO read returning `0xFFFFFFFF`.
- Abort / LUN reset / target reset entry points are empty stubs.

## 11. Hardware observations (Mac Studio, 2026-11-14)

First contact with the real unit, read from the IORegistry with the scaffold driver attached.
No MMIO was touched.

- Thunderbolt: vendor "Drobo" (`0x001C`), device "8D" (`0x4`), Thunderbolt 3 mode, 40 Gb/s,
  NHI firmware 33.1.
- PCI: `0x4452:0x3844`, subsystem `0x4452:0x3844`, revision `0x08`, class code `0x010078`
  (mass storage / SCSI), `IOName` "scsi", tunnelled.
- PCIe link status `0x1042`: 5 GT/s, x4.
- MSI capability present, message control `0x0080` (64-bit address capable, one vector).
- Memory ranges (resolves open question 1):

  | Config offset | BAR | Type | Size | Role |
  |---|---|---|---|---|
  | `0x10` | BAR0 | 32-bit memory | 1 MiB | register window ("device memory 0") |
  | `0x18` | **BAR2** | 32-bit memory | 64 KiB | `DroboPort` region ("device memory 1") |

  So the kext's "BAR1" is the second memory range, which is config-space **BAR2**. In
  PCIDriverKit terms: `GetBARInfo(0)` and `GetBARInfo(2)`, and use the returned
  `memoryIndex` for `MemoryRead32`.
- The scaffold dext matched and started: `DroboSCSIController` is in the registry under the
  device with `SCSI Initiator Identifier = 1`, `IOCommandPoolSize = 4`,
  `IOMaximumSegmentAddressableBitCount = 32`, i.e. the family called our callbacks.
- Known gap: the dext's `os_log` lines did not appear in the unified log, so the config dump
  above comes from the registry rather than from the driver. Logging needs fixing before the
  next stage (try `IOLog`, and capture with `log stream` during a replug).

### 11.1 DroboPort probe (driver v0.2.0 / v0.3.0, 2026-11-14)

The probe enabled PCI memory space, set `HOST_BAR_READY`, and read BAR2. Raw results are
published by the driver under the `DroboProbe` registry property.

**Handshake.** `BAR0[0x21878]` read `0x00000000`, then `0x00200000` after the write. The
firmware did not clear bit 21 within 5 s and BAR2 held unrelated bytes at that point. Four
minutes later (next driver start, no further writes) BAR2 held a valid `DroboPort` structure
while bit 21 was **still set**. So on this firmware the structure appears some time after the
handshake write, and "bit cleared" is not a reliable completion signal by itself; test the
signature. Bus mastering was never enabled, so it is not required for this step.
`BAR0[0x2187C]` (the inbound mask) read `0x0000FFFF`.

**Header.** Signature `"DroboPort"`. Word at `0x10` = `0x00000C24`, which equals the end of
the last table, so it is the structure's total size. All offsets below are inside it:

| Field | Offset in BAR2 |
|---|---|
| LUN table | `0x048` |
| Capabilities | `0x248` |
| Serial number | `0x288` (15-character ASCII string) |
| Inbound interrupt table | `0x2E8` |
| Outbound interrupt table | `0x558` |
| SCSI request / response list | `0x774` / `0x7FC` |
| SysControl request / response list | `0x904` / `0x98C` |
| TM request / response list | `0xA94` / `0xB1C` |

The gaps match the reverse-engineered sizes exactly: LUN table 32 × 16 = `0x200`,
capabilities `0x40`, inbound table `0x24 + 7 × 0x54 = 0x270`, outbound
`0x24 + 6 × 0x54 = 0x21C`, response lists `0x108`. This confirms the structure layouts in
sections 5, 6, 8 and 9.

**Capabilities.**

| Field | Value |
|---|---|
| Interface Version | **6** (so: 32-byte response entries, summary interrupt Out[5] in use) |
| Transfer Mode | 3 |
| Max Transfer Size | `0x80000` (512 KiB) |
| Max Outstanding Transactions | 64 (so task count 32) |
| Max LUNs | 32 |
| Drobo Port Flags | `0xFF` |
| Max Burst Size | 8 |
| Stall Size | 8 |
| Max SGL Entries | 1024 |
| Host Interface Version | 0 (not yet written by a host) |
| remaining 6 words | 0 |

Queue windows: SCSI request/response 8, SysControl 1, TM 1; all counts 0.

**Interrupt tables.** First header word is the entry count (7 inbound, 6 outbound). The
leading word of each entry is its index. Every action has size 4.

Inbound (host → Drobo): cause register `0x21878`, mask register `0x2187C`.
Trigger = write the bit (op 3), state = `cause & bit`.

| Index | Bit | Meaning |
|---|---|---|
| In[0] | `0x00020000` (17) | SCSI request ready |
| In[1] | `0x00800000` (23) | unused by the kext |
| In[2] | `0x02000000` (25) | unused by the kext |
| In[3] | `0x04000000` (26) | SysControl request ready |
| In[4] | `0x08000000` (27) | TM request ready |
| In[5] | `0x00010000` (16) | Driver ready |
| In[6] | `0x00200000` (21) | Host BAR ready, the same bit the kext hard-codes |

Outbound (Drobo → host): cause register `0x21870`, mask register `0x21874`.
State = `cause & bit`; clear = write `~bit` to the cause register (op 3, write-zero-to-clear);
enable = `mask |= bit`; disable = `mask &= ~bit`.

| Index | Bit | Meaning |
|---|---|---|
| Out[0] | `0x00000002` | SCSI response ready |
| Out[1] | `0x00000800` | TM response ready |
| Out[2] | `0x00000400` | SysControl response ready |
| Out[3] | `0x40000000` | unused by the kext |
| Out[4] | `0x00000001` | Adapter ready |
| Out[5] | `0x00000004` | Summary interrupt |

Endpoint interrupt enable (outbound header): `BAR0[0x20B08] |= 0x80010000`;
disable: `BAR0[0x20B08] &= 0x7FFEFFFF`.

At probe time the outbound cause and mask both read 0: **adapter ready was not asserted**.

**LUN table: all 32 entries zero.** No LUN is presented yet. Not yet known whether the Drobo
only fills the table after the host writes Host Interface Version and signals driver ready
(the next steps of the bring-up sequence), or whether the disk pack was not mounted. That is
the first thing the next stage answers.

### 11.2 Second run after a cable replug (driver v0.5.0, 2026-11-14)

After unplugging and replugging Thunderbolt, the same probe behaved exactly as the kext
expects, which means the 11.1 run had caught the firmware before it was ready:

- `HOST_BAR_READY`: one write, bit 21 **cleared by the firmware within the first 500 ms poll**.
- Inbound mask `BAR0[0x2187C]` = `0x0C23FFFF`: the firmware has now enabled bits 16, 17, 21,
  26 and 27, i.e. exactly the doorbells the kext uses (In[5], In[0], In[6], In[3], In[4]).
  In 11.1 it was `0x0000FFFF`. **This mask is a usable "firmware is listening" indicator.**
- Outbound cause `BAR0[0x21870]` = `0x00000001`: **adapter ready asserted** before the host
  wrote anything else. `BAR0[0x20B08]` read `0x11000000`.
- Host Interface Version written as 1 and read back as 1. No other capability changed.
- **Six LUNs present.** The LUN entry layout is now known:

  | Offset | Type | Field |
  |---|---|---|
  | `0x00` | u32 | Present flag (1) |
  | `0x04` | u32 | Block size (`0x200` = 512) |
  | `0x08` | u64 | Block count |

  | LUN | Block count | Size at 512 B |
  |---|---|---|
  | 0 | `0x4000000000` | 128 TiB |
  | 1 | `0xFA000000` | 1.95 TiB |
  | 2 | `0x1` | 512 bytes |
  | 3 | `0x20000000` | 256 GiB |
  | 4 | `0xFFFFFF78` | 2.00 TiB |
  | 5 | `0x800000000` | 16 TiB |

  These are the sizes the Drobo advertises (it thin-provisions), not the installed capacity.
  What each LUN is (user volumes versus internal ones such as the 1-block LUN 2) is not known
  yet; INQUIRY and a read of each LUN's partition map will tell.

Driver-lifecycle lesson from this stage: a dext that creates its own `IODispatchQueue` must
`Cancel` it in `Stop` and finish `Stop` from the cancel handler. v0.3.0/v0.4.0 did not, and
hung in "terminating for upgrade" until the device was unplugged.

### 11.3 First read-only I/O (driver v0.13.0, 2026-11-14)

The read path works. With the driver publishing the LUNs as write-protected disks, macOS
enumerated all six, read their partition maps and mounted three HFS+ volumes read-only. In the
first minutes: 3,190 read requests, 290 MB, **0 errors**, 0 write attempts reaching the driver's
reject path. Last SRB response `1`, SCSI status `0`.

This confirms, against hardware:

- the block request layout (section 8.2) with a single SGL entry and a zero-length terminator;
- the request list / `QueueEntry` format and the In[0] doorbell (`BAR0[0x21878] = 0x00020000`);
- the 32-byte response entries of interface version 6, with SRB response at entry `+0x14`,
  SCSI status at `+0x18`, bytes transferred at `+0x08`;
- completion signalling through Out[0] in `BAR0[0x21870]`, cleared by writing `~bit`, **without
  any interrupt enabled**: the cause bit is set regardless of the mask, so polling works;
- transaction IDs starting at 0 and incrementing by one per request;
- 32-bit bus addresses from the Apple silicon DART for both the request structure
  (`0x80000000`) and the data buffers. Open question 6 is answered: DMA works.

What the LUNs are:

| LUN | Advertised | Contents |
|---|---|---|
| 0 | 140.7 TB (128 TiB) | GPT, HFS+ volume, 3.58 TB used |
| 1 | 2.1 TB | GPT, APFS container, one volume |
| 2 | 512 bytes | no partition map; not a user volume |
| 3 | 274.9 GB | GPT, HFS+ volume, 184 GB used |
| 4 | 2.2 TB | GPT, APFS container, one volume |
| 5 | 17.6 TB (16 TiB) | GPT, HFS+ volume, 190 GB used |

The HFS+ volumes mount read-only. The APFS containers are detected but do not mount on a
write-protected device.

SCSIControllerDriverKit lessons learned getting here (each one cost a driver version):

1. Create an `IODispatchQueue` named `"AuxiliaryQueue"` and register it with
   `SetDispatchQueue` (after super `Start` is fine). Without it `UserCreateTargetForID` never
   returns. `SetDispatchQueue("InterruptQueue", …)` is rejected with `kIOReturnBadArgument`.
2. Never call `UserCreateTargetForID` from the queue that serves SCSI tasks: target creation
   sends TEST UNIT READY / INQUIRY synchronously and waits for the answers.
3. `UserGetDMASpecification` must return **`kDMAOutputSegmentHost64`**. With
   `kDMAOutputSegmentLittle32` (what the kext's `IODMACommand` used) the family delivers
   commands without data but silently fails every data-carrying command before it reaches the
   dext. This was the bug that blocked discovery; address width is still limited to 32 bits by
   `numAddressBits`.
4. Call `UserReportHBAConstraints` with all seven required keys from
   `UserInitializeController`, and start `UserMapHBAData` task IDs at 1 (0 is reserved).
5. Cancel every queue you created in `Stop` and finish `Stop` from the last cancel handler, or
   upgrades hang in "terminating for upgrade" until a reboot.
6. The dext's `os_log` / `IOLog` output did not show up in `log show` in this setup. Publish
   state with `SetProperties` and read it with `ioreg` instead.

### 11.4 Interrupts and concurrent requests (driver v0.14.0, 2026-11-14)

- **MSI works.** `ConfigureInterrupts(kIOInterruptTypePCIMessaged, 1, 1)` succeeds, the
  messaged interrupt is at index 0, and an `IOInterruptDispatchSource` on it fires once the
  device side is enabled.
- **Device-side enable**, taken from the outbound table and now confirmed: set the summary bit
  (`0x4`, Out[5]) in the outbound mask `BAR0[0x21874]`, then `BAR0[0x20B08] |= 0x80010000`.
  Only the summary bit needs unmasking on interface version >= 3; the handler clears it
  (`BAR0[0x21870] = ~0x4`) and then checks the per-channel response bits.
- **Several requests can be outstanding.** Requests are queued in up to 32 host-side slots and
  submitted in bursts (window 8, so at most 7 per doorbell, as the kext does). The response
  entry's first word echoes the request's `queueIndex` field (`+0x08`), which is what maps a
  completion back to its slot; the transaction ID is checked as well.
- **BARs can be mapped straight into the dext** with `IOPCIDevice::_CopyDeviceMemoryWithIndex`
  + `CreateMapping`, which removes a kernel round trip per register access.
- First run: 3,702 reads, 3,669 completed from the interrupt handler and 7 by the fallback
  timer, 0 errors, peak 7 requests in flight, the request doorbell never found busy.

### 11.5 Passthrough channel and management pages (driver v0.17.0, 2026-11-14)

The passthrough ("TM") channel works, and the Drobo's management pages are readable through it.

- Request list `DroboPort[0x30]`, response list `DroboPort[0x34]`, window 1. Doorbell In[4]
  (`BAR0[0x21878] = 0x08000000`), completion Out[1] (`0x800` in `BAR0[0x21870]`, cleared by
  writing `~0x800`). Transaction ID 0, as in the kext. Response entries use the same 32-byte
  format as the block channel.
- **A data-carrying passthrough request must set a buffer-mode flag.** Section 8.3 gave the
  flags as `0x00410020` / `0x00420020`; the kext then ORs in one more bit:
  `0x10` when an SGL follows at `+0x58`, or `0x08` when there is exactly one segment, in which
  case the pointer field at `+0x28` holds the **buffer's bus address** and the first SGL
  length is zeroed. Without either bit the Drobo completes the request with SRB response `4`
  (error) and transfers nothing. With `0x08` and the bus address it returns SRB response `1`.
- The management protocol is MODE SENSE(10) (`5A 00 3A <sub-page> 00 00 00 <len16> 00`), vendor
  page `0x3A`, as documented by the open-source
  [drobo-utils](https://github.com/petersilva/drobo-utils) project. Each reply starts with a
  4-byte header `7A <sub-page> <len16>` and is big-endian.

Pages verified on the 8D (firmware 4.2.3):

| Sub-page | Content | Notes for the 8D |
|---|---|---|
| `0x01` | Config: slot count, max LUNs, max LUN size | Slot count is **9**: eight bays plus the mSATA bay |
| `0x02` | Capacity: free, used, virtual, unprotected (u64 bytes each) | as drobo-utils |
| `0x03` | Slot info: count byte, then 72-byte records | Record: u16 (`0x0046`), slot id, physical bytes u64, managed u64, status byte, identity[32] = vendor[8] + product[16] + interface[8] (`"SATA"`), short identity[16], u32. Status `0x80` = empty, `0x04` = blinking yellow/green (rebuilding) |
| `0x05` | Settings: UTC u32, offset u16, name[32] | as drobo-utils |
| `0x06` | Protocol version | `00 0B` |
| `0x08` | Firmware | 6 numeric bytes, build date[32], platform[16] (`"ArmMarvell"`), version[16] (`"4.2.3"`). The readable version is the third string, not the leading bytes |
| `0x09` | Status: flags u32, relayout count u32 | Flag bits as drobo-utils (`0x0200` relayout in progress, `0x0040` no redundancy, …). Bits `0x8000` and `0x10000` were also set and are not documented there |

### 11.6 Options pages, write path and app commands (driver v0.19–v0.21, 2026-11-15)

- **Options pages work on the 8D.** Sub-page `0x30` returned `55 5F …` (yellow threshold 85 %,
  red 95 %). Sub-page `0x31` returned flags `0x07` (dual disk redundancy, spin-down enabled,
  manual volume management) and a spin-down delay of 14 minutes, matching drobo-utils' layout.
- **Slot info with 9 slots** returns the mSATA cache drive as the ninth record.
- **Write path** (implemented, not yet exercised): same block request as a read with operation
  `0x00400031`. Each LUN stays write-protected (MODE SENSE WP bit) until enabled; the driver
  destroys and re-creates its SCSI target so macOS re-reads the write-protect state.
  SYNCHRONIZE CACHE is still answered by the driver rather than forwarded on the
  system-control channel, whose request flags remain undecoded.
- **App commands** go through an `IOUserClient` (`DroboUserClient`, selector 0). On the
  passthrough channel, from drobo-utils and not yet verified on the 8D:
  blink = `EA 10 00 06 00 <seq> 20 00 01 00` (1 byte data-in), standby = same with `0D`,
  rename/set clock = MODE SELECT(10) `55 01 7A 05 00 00 00 00 2A 00` with a 42-byte page
  (`7A 05 00 26`, UTC u32, offset u16, name[32]) sent data-out with flags `0x00420020 | 0x08`.
- **The 8D's one-block LUN** (LUN 2 here) has no partition map and makes macOS show "The disk
  you attached was not readable". The driver no longer publishes single-block units.
- **Stop must not wait on the I/O queue.** A `DispatchSync` onto it from `Stop` could hang
  termination; the system then killed and relaunched the old dext and the upgrade stayed stuck
  in "terminating for upgrade". `Stop` now quiesces asynchronously and a five-second watchdog
  completes it if the cancel handlers have not all run.

### 11.7 System-control channel, sleep/wake, settings (driver v0.22.0, 2026-11-15)

Decoded from the kext and implemented; **none of this section has run on hardware yet.**

- **System-control request** (`SysControlChannel::BuildDroboRequest` @ `0xbd2a`): the 0x20-byte
  header with kind `2` and total length `0x28`, followed by one u32 command word at `+0x20`.
  No data phase. Command `5` is sent for SYNCHRONIZE CACHE and WRITE BUFFER, `3` for START STOP
  UNIT. Request list `DroboPort[0x28]`, response list `DroboPort[0x2C]`, doorbell In[3]
  (`0x04000000`), completion Out[2] (`0x400`), transaction ID 0. The driver now forwards
  SYNCHRONIZE CACHE this way when any LUN is writable, one flush at a time, completing every
  waiting task when the Drobo answers.
- **Sleep / wake** (`setPowerState` @ `0x267e`): on sleep each channel waits for its in-flight
  requests. On wake the kext rings driver-ready (In[5], `0x00010000`), and for interface
  version >= 6 waits up to 30 x 200 ms for that bit to clear, rewrites Host Interface Version = 1
  and re-arms the outbound interrupts. The dext does the same from `SetPowerState`.
- **Settings**: MODE SELECT(10) page `0x7A` sub-page `0x31`, payload flags u64 + spin-down
  minutes u16 + unused network fields, per drobo-utils' `SetOptions`. Exposed in the app only
  when the unit is healthy.

### 11.8 Blink command restarts the unit (app v0.23.0, 2026-11-15)

Reported by the maintainer on the 8D (firmware 4.2.3) while it was rebuilding: after pressing
Blink Lights the lights never blinked, the Drobo stopped responding for a few minutes and then
restarted, and this repeated. During one such restart the driver was seen sitting in the
`waiting-for-firmware` stage for about five minutes before returning to `ready`.

- What is sent: vendor command `EA 10 00 06 00 <seq> 20 00 01 00` with one byte data-in, on the
  passthrough channel, the format taken from drobo-utils (11.6). It was never verified on this
  model.
- This is one person's observation, not a controlled test: the unit was mid-rebuild and had no
  redundancy, and no capture of the command's response was taken. It was not retried to confirm,
  because each attempt costs a restart.
- **Blink is turned off in the app** until the 8D's own format is known (backlog item 1,
  Drobo Dashboard). The driver still accepts the command from its user client.
- **Standby (Shut Down) is the same command with sub-command `0D`** and is equally unverified.
  Treat it as suspect. Rename and Settings use MODE SELECT, a different path.

### 11.9 Slot page fields settled; Drobo Dashboard's page map (2026-11-15)

**Slot page `03`, from a diagnostics dump of the 8D.** The two fields that were unknown carry
nothing new: the 16-byte "short identity" is the first 16 bytes of the 32-byte identity again
(eight spaces, then the start of the model), and the trailing u32 was zero for every bay. The
identity's vendor field is blank and its product field is the model truncated to 16 characters.
So page `03` has no temperature, serial number or error data.

**Drobo Dashboard 3.6.1, static analysis of its service** (`DDService64d`, x86_64, symbols
intact; nothing was sent to the Drobo). Each management page is a class under `ESAProtocol::`
whose `getSubPageType()` returns its sub-page code. The codes this driver already uses match
(`01 02 03 05 06 08 09 30 31`), which is the check that the method is right. **[obs]**

| Sub-page | Class | Polled here |
|---|---|---|
| `01` | `ESAConfigurationInfo` | yes |
| `02` | `ESACapacityInfo` | yes |
| `03` | `ESASlotInfo` | yes |
| `04` | `ESALUNInfo` | no |
| `05` | `ESASystemSettings` | yes |
| `06` | `ESAProtocolVersion` | yes |
| `07` | `ESALUNInfo2` | no |
| `08` | `ESAFirmwareInfo` | yes |
| `09` | `ESAStatusInfo` | yes |
| `0A`–`0D` | `ESASetCHAP`, `ESASetSingleInitiator`, `ESASetUsedCapacity`, `ESASetLUNName` | no (setters) |
| `10` | `ESASnapshotInfo` | no |
| `11` | `ESADiskPackInfo` | no |
| `12` | `ESADeviceInquiry` | no |
| `15` | `ESALUNMappingInfo` | no |
| `30`, `31` | `ESAOptions`, `ESAOptions2` | yes |
| `32` | `ESAModePageB1200NetworkInterfaces` | no |
| `33` | `ESASystemInfo` | no |
| `34` | `ESASystemPerformance` | no |
| `35` | `ESASlotInfo2` | no |
| `36` | `ESAPowerSupply` | no |
| `37` | `ESAFanInfo` | no |
| `38` | `ESAControllerCard` | no |
| `39` | `ESAExpanderInfo` | no |
| `3A` | `ESABatteryInfo` | no |
| `80` | `ESADeviceSerial`, `ESAEventMessages` | no |

Which of these the 8D's firmware answers is not known: several classes size themselves from the
protocol version, and the 8D reports `00 0B`.

**Per-drive record of page `35`**, `ESASlotInfoStruct2::parse` @ `0x10009d534`, field names from
`ESASlotInfoStruct2::print` @ `0x10009d6a6`. 108 (`0x6C`) bytes, big-endian. **[obs]**

| Offset | Type | Field |
|---|---|---|
| `0x00` | u8 | slot id |
| `0x01` | u8 | slot status |
| `0x02` | u16 | error count |
| `0x04` | u32 | disk state |
| `0x08` | u8 | disk type |
| `0x09` | u8 | temperature |
| `0x0A` | u8 | life remaining |
| `0x0B` | u8 | rotational speed |
| `0x0C` | char[44] | manufacturer and model |
| `0x38` | char[12] | firmware revision |
| `0x44` | char[24] | serial number |
| `0x5C` | u64 | total capacity |
| `0x64` | u64 | managed capacity |

Not yet read: the header in front of these records (`ESASlotInfo2::parse` @ `0x10009d8c4`), the
units and encodings of disk state, disk type, life remaining and rotational speed, and the
layouts of pages `33`, `34`, `36`, `37`, `38` and `11`. The Drobo does not appear to pass
S.M.A.R.T. attributes through: the only "SMART" strings in the service are a drive vendor name.

**Page `35` header**, `ESASlotInfo2::parse` @ `0x10009d8c4`: after the usual `7A 35 <len16>`,
byte `0x08` of the page is the slot count and byte `0x09` the record size; records start at
`0x0C`. The largest page is `0x51C` bytes (12 + 12 × 108). **[obs]**

Since driver v0.25.0 the driver can poll page `35` (key `Slots2` under `DroboHealth`). It is off
until the app turns it on (Advanced tab, "Read drive details"), the app holds it off while the
unit is rebuilding or has no redundancy, and the driver gives it up until it restarts if the
Drobo answers with an error or not at all. **It has not been tried on hardware.**

### 11.10 First write through the driver (2026-11-15)

Reported by the maintainer: with Allow writes on for a volume, a file copy to the 8D completed
and appeared to work. No checksum comparison after eject and remount has been done yet, and the
unit was rebuilding at the time, so the write path stays "unverified" until backlog item 3 is
carried out.

### 11.11 System, performance, power and fan pages; USB units; volume icons (2026-11-15)

More static analysis of Drobo Dashboard 3.6.1's service (`DDService64d`); nothing was sent to a
Drobo. Offsets are from the start of the page, including the `7A <sub-page> <len16>` header;
values are big-endian. Field names are the XML node names the service writes in
`ESADevice::GetSysInfo`, `GetFanInfo`, `GetPowerInfo` and `GetPerformance`. **[obs]**

| Page | Length | Layout |
|---|---|---|
| `33` system info (`ESASystemInfo::parse` @ `0x10009c07e`) | `0x18` | `0x08` u32 `UpTime`, `0x0C` u32 `Temperature`, `0x10` u32 not exported |
| `34` performance (`ESASystemPerformance::parse` @ `0x10009c182`) | `0x20` (`0x1C` on older protocol) | `0x08` u32 `Iops`, `0x0C` u32 `ReadThroughout`, `0x10` u32 `WriteThroughout`, `0x14` u32 not exported, `0x18` u32 `TierIOps` |
| `36` power supply (`ESAPowerSupply::parse` @ `0x10009c27a`) | `0x2D` | `0x09` u16 and `0x0B` u16 `Health` (two supplies), `0x0D` char[16] and `0x1D` char[16] `Serial` |
| `37` fan (`ESAFanInfo::parse` @ `0x10009c394`) | `0x2E` | `0x08` char[16] `Serial`, `0x18` u16 `Health`, `0x1A` four u32 `RPMLevel`, `0x2A` four u8 `RPMHealth` (newer protocol only) |

Units are not stated anywhere in the binary. The app treats uptime as seconds and temperature as
degrees Celsius, and shows fan values as "levels"; **all three are assumptions to check against
the first real dump**. The health words are kept in diagnostics only.

Since driver v0.26.0 these four pages are polled with page `35` when the app's "Read drive and
system details" switch is on (keys `System`, `Performance`, `Power`, `Fan` under `DroboHealth`).
A page the Drobo answers with an error is dropped on its own; if one goes unanswered all the
optional pages are dropped and polling pauses 30 seconds. **None has been tried on hardware.**

**USB units.** Dashboard does not reach USB (or FireWire) Drobos through macOS's own disk
driver. It installs a second kext, `TrustedDataSCSIDriver.kext`, whose personalities attach to
`IOSCSIPeripheralDeviceNub` for devices whose INQUIRY vendor is Drobo (products include
`Drobo3`, `DroboPro`, `Mini`, `5D3`, `8D`, `B810i`), as peripheral device type 0 with its own
user client for SCSI passthrough. So a user-space app cannot read the management pages of a USB
Drobo by itself; the DriverKit equivalent would be a second driver built on
`SCSIPeripheralsDriverKit` that takes over the disk. **[obs]**

**Volume icons.** The model icons (`Drobo.icns`, `5D-TB.icns`, `Mini-TB.icns`, …) are resources
of that same kext, and the service also copies a `.VolumeIcon.icns` onto volumes
(`DNASShareMapInfo::DroboCustomShareIcon`, which skips a volume that already has one). This
project's app writes its own `.VolumeIcon.icns` (through `NSWorkspace.setIcon`), only on
volumes with Allow writes on and only when asked. **[obs]**

### 11.12 Page `35` on the 8D (driver v0.25.0, 2026-11-15)

First hardware result for the optional pages: the 8D (firmware 4.2.3, protocol `00 0B`),
rebuilding at the time, answers sub-page `35` with SRB response 1, status 0 and 984 bytes:
header `7A 35 03 D4 D8 03 01 00 09 6C 00 00` (nine slots, record size `0x6C`), then nine
records laid out as in 11.9. Polling continued with zero errors. What the records showed:

- Slot id and status match page `03`. Error count was 0 for every drive.
- **Temperature (`0x09`) is 0 for every drive**: this firmware does not report it here. The app
  treats 0 as "not reported".
- **Life remaining (`0x0A`)** is a percentage: 100 for the eight hard disks, 99 for the SSD.
- **Rotational speed (`0x0B`)** is rpm / 200 for hard disks (27 on the 5400 rpm models, 36 on
  the 7200 rpm models) and 1 for the SSD.
- **Disk type (`0x08`)** was 0 for hard disks and 2 for the SSD.
- Disk state (`0x04`) was `0x00000010` for hard disks and `0x00000020` for the SSD while
  rebuilding; meaning still unknown.
- Model (padded to 44, ending in the interface name), firmware revision and serial number are
  filled in. Total capacity matches page `03`; the managed-capacity field was 0.

Pages `33`, `34`, `36` and `37` need driver v0.26.0 and have not been tried.

### 11.13 Pages `33`, `34`, `36`, `37` on the 8D (driver v0.26.0, 2026-11-15)

Same unit, still rebuilding, minutes after v0.26.0 was activated:

- **`33` system info: answered**, 24 bytes: `7A 33 00 10 14 00 01 00 00 00 13 0C 00 00 00 1C 00 …`.
  Uptime `0x130C` = 4876, which is 81 minutes and matches when the unit was last power-cycled,
  so **uptime is in seconds**. Temperature `0x1C` = 28, plausible as **degrees Celsius** for
  the enclosure.
- **`34` performance: answered**, 32 bytes. `Iops`, `ReadThroughout`, `WriteThroughout` and
  `TierIOps` were all 0 while the Mac was idle; the unexported u32 at `0x14` was `0x23`.
  Units still unknown.
- **`36` power supply and `37` fan: refused.** The driver recorded two health errors, dropped
  those two pages (`ExtendedFailedMask` 24) and kept polling everything else with no further
  errors. The 8D does not offer them, at least on this firmware.

### 11.14 System operations: why Blink hung the 8D, and the correct framing (2026-11-15)

From Drobo Dashboard 3.6.1's service, `ESASystemOperationRequest`'s constructor @ `0x1000c56e4`
and `ESASCSISession::sendSystemOperation` @ `0x1000a33cc`. **[obs]**

A system operation is a 10-byte vendor CDB:

| Byte | Value |
|---|---|
| 0 | `EA` |
| 1 | `10` |
| 2 | `80` for an operation that reads data back, `00` otherwise |
| 3 | operation code |
| 4 | sequence number, a counter the host increments per request |
| 5 | `00` |
| 6 | `21` |
| 7–8 | data length, big-endian |
| 9 | `00` |

Operations with no parameter still carry **one zero byte, sent to the Drobo** (data-out), length
1. Operation codes seen: `03` restart (`restartESA`), `06` identify, i.e. blink
(`identifyESA`; a variant sends a 4-byte big-endian argument), `0D` standby
(`ESA_SYSOPID_STANDBY_ESA`, named in a trace string), `17` power off (`powerOffESA`), `18` set
LED dim level (2-byte big-endian value, data-out) and `21` get LED dim level (2 bytes back).

**What this driver sent up to v0.26.0** came from drobo-utils: `EA 10 00 <op> 00 <seq> 20 00 01
00` as a one-byte data-*in* request. Three differences: the sequence number was in byte 5
instead of byte 4, byte 6 was `20` instead of `21`, and the data direction was reversed. That
malformed request is the likely cause of 11.8. v0.27.0 sends Dashboard's framing for blink,
standby and the new restart command. **Not yet tried on hardware.**

Not implemented: LED dim level (the valid range of the value is not known yet) and the SSD
cache switch (it is one of the feature bits in options page `31`, whose bit meanings beyond
dual redundancy and spin-down have not been mapped; on the maintainer's unit bit 2 is also set).

### 11.15 Blink confirmed; LED dim level; SSD cache (2026-11-15)

- **Blink works on the 8D with the corrected framing** (driver v0.27.1): the maintainer saw the
  lights blink, the command returned SRB response 1, and the unit carried on. That confirms
  11.14, and with it the framing of standby and restart, which are still untried. The plain
  form blinks for a long time; Dashboard's app has separate "turn on" and "turn off" actions
  and an `IdentifyInterval` value, which is the 4-byte argument of the other `identifyESA`
  variant. Not implemented.
- **LED dim level.** Dashboard's settings view (`GeneralSettingsView.xaml`) defines the "Dim
  Lights" slider as `Minimum="0" Maximum="9" TickInterval="1"`, and the service passes the
  value straight to operation `18` (set, 2 bytes out) and reads it with `21` (2 bytes back).
  Driver v0.28.0 implements both; the app's Settings sheet has the slider. **Not yet tried on
  hardware.**
- **SSD (hot data) cache.** The service has no command for it. Dashboard's app only has status
  strings for it (accelerator active or not active), so it appears to be automatic when the
  mSATA bay holds a good drive, not a switch. The app shows the SSD bay's state on Summary and
  does not claim more than that.


### 11.16 Disk state, disk type, bay light states; the event log request (2026-11-16)

Static analysis of Drobo Dashboard 3.6.1 (service and UI binaries); nothing was sent to a
Drobo. **[obs]** unless marked.

**Disk state** (page `35`, record offset `0x04`, u32). Dashboard reads only the low four bits
(`DDUtils::GetDiskState`, `ESAAlertHistory::GetDiskState`, both mask with `0x0F`):

| Value | Meaning |
|---|---|
| 0 | Good |
| 1 | Healed |
| 2 | Warning |
| 3 | Failed |

The 8D also sets `0x10` (hard disks) or `0x20` (SSD). Dashboard ignores those bits and their
meaning is not known. The app shows the low four bits as "State" and treats 2 and 3 as a
flagged drive in the drive history.

**Disk type** (offset `0x08`): 0 SATA hard disk, 1 SAS hard disk, 2 SATA SSD, 3 SAS SSD,
4 mSATA SSD (the accelerator bay), `0xFF` not provided.

**Bay status byte** (page `03`, and page `35` offset `0x01`): bit `0x80` means empty; the low
four bits are the light: 1 red, 2 yellow, 3 green, 4 flashing yellow/green (rebuild), 6
flashing red. 5, 7 and 8 are flashing green/red, yellow/red and yellow/off **[inf]** from the
drawing code.

**The event log is not a management page.** `ESAEventMessages` (sub-page `80`) is unused in
Dashboard and carries only "page changed" notices. `ESADeviceSerial` shares the number because
it is the standard INQUIRY VPD page `0x80`. The log users see comes from
`ESASCSISession::getUserEventLog`: system operation `0x22`, data-in,

    EA 10 80 22 <sequence> 00 <20 on the first chunk, 00 after> 80 00 00

32 KiB per chunk, repeated until a short chunk (the exact stop test is **[inf]**). The answer
is text, one event per line: a 24-character timestamp, `": "`, then `<id>:<key>=<value>,...`.
Event ids run from 100 to 1643 (100 power on, 200 disk inserted, 211 disk channel failure,
229 disk expunged, ...); names and severities are tables in the UI binary.

### 11.17 Event log read in the driver (driver v0.29.0, 2026-11-16)

The driver sends the request above only when the app asks (Events tab, "Read from Drobo"),
never on its own. **Not yet tried on a Drobo**: everything below is how it is built, not what
was observed.

- The data goes to a second DMA buffer of 32 KiB, because the passthrough data area is 4 KiB.
  The buffer must come back as one segment below 4 GiB; if it does not, the command answers
  "unsupported" and nothing is sent.
- Chunks are requested with Dashboard's exact bytes and length. The buffer is cleared first and
  the text has no zero bytes, so the first zero ends a chunk; a chunk that is not full, or one
  starting with `0x04`, ends the log. At most 8 chunks (256 KiB) are kept.
- Dashboard's abort request after a failure (`EA 10 00 22 <sequence> 00 40 00 00 00`) is not
  sent.
- No answer within 10 s: the read is given up, status polling pauses for 2 minutes (so a late answer
  cannot be taken for a status page) and then carries on. Block I/O is not involved.
- The app copies the text out through user-client selector 1, 4 KiB per call. `DroboStatus`
  gains `EventLogState` (0 never, 1 reading, 2 read, 3 failed, 4 no buffer), `EventLogLength`,
  `EventLogChunks`, `EventLogSRB`; `CommandFormat` is 4.
- Times are parsed as Pacific time, as Dashboard does **[inf]**; bay numbers are shown as the
  Drobo prints them, and whether they count from 0 or 1 is not known (from 0: see 11.22).
- The app's event descriptions are this project's wording for ids 100 to 671. The NAS-only ids
  (1500 and up) are shown as numbers.

### 11.18 Event log read on the 8D (2026-11-17)

First read on hardware, driver v0.29.0, firmware 4.2.3. **[obs]**

- The request is answered: chunks come back full, as text in the format of 11.16.
- v0.29.0 took a new sequence number for every chunk, and the 8D answered each one from the
  oldest entry: eight identical 32 KiB chunks (October 2019 to March 2020). Dashboard reads the
  session counter once, before its loop (`0x1000a843f`), and sends that same number with every
  chunk. v0.29.1 does the same. **Not yet tried.**
- The log is oldest first, about 32 KiB per five months on this unit, so a full log is well
  past the old 256 KiB limit. The limit is now 64 chunks (2 MiB).

### 11.19 Drive-level calls in Dashboard that this project does not send (2026-11-17)

From `DDService64d`, by disassembly only. **None of these has been sent to a Drobo.**

- `ESASCSISession::insertRemoveDrive(bool, int, int*)` @ `0x1000a92fa`: MODE SENSE(10)
  `5A 08 3A <E1 insert | E2 remove> <slot> 00 00 00 08 00`, 8 bytes in, a u32 result at
  offset 4. Reached from the service commands `eCmdInsertDrive` / `eCmdRemoveDrive` with a slot
  number from the request; the service does not check demo mode first. The UI binary has the
  command names but no screen that sends them; the only related screen is the demo-mode dialog,
  so this is most likely the demonstration feature (pretend a drive was pulled) **[inf]**.
  What the firmware does with it on a real disk pack, or to a drive marked failed, is unknown.
- `ESASCSISession::getATAIdentify` @ `0x1000a7ae8` (`ESAATAIdentifyWithInquiry`): takes no slot
  number and is only called from `getDeviceSerial` for one connection type. It reads the
  Drobo's own identity, not a member drive's.
- `ESASCSISession::runEsaCommand(u16, u8*, Buffer&)` @ `0x1000a8bcc`: system operation `0x0A`,
  data-out, the caller's bytes as payload, then a read of up to 0x800 bytes. The service passes
  through a `Params` string from the request (`eCmdRunESACommand`). No command strings are in
  either binary, and the UI has no screen for it: a support hook.
- No request in either binary is named for clearing a failed drive, retrying a drive, or
  reading S.M.A.R.T. data or self-test results.

### 11.20 Volume create, delete and resize in Dashboard (2026-11-17)

From `DDService64d`, by disassembly only. **None of these has been sent to a Drobo, and this
project does not send them.** The direct-attached path is `ESABlockDevice`; `ESAMPDevice` is
the iSCSI one and builds the same requests.

All four are system operations in the data-out form this driver already uses for LED dimming,
`EA 10 00 <operation> <sequence> 00 21 <length16> 00` (data-in for the read: `EA 10 80 ...`).

| What | Operation | Data | Where |
|---|---|---|---|
| Delete a volume | `0x13` | 4 bytes out: u16 BE unique volume ID, u8 unit number (`FF` when Dashboard could not find the volume in its list), `00` | `ESABlockDevice::DeleteUniqueLUN` @ `0x100064008` |
| Create a volume | `0x12` | 12 bytes out: u64 BE size (the request's `Size`, unit not confirmed, bytes **[inf]**), u8 flags (the request's `Flags`), `00`, u16 BE unique volume ID | `ESABlockDevice::CreateLUN` @ `0x10006654e` |
| Next free unique volume ID | `0x20` | 2 bytes in: u16 BE | `ESASCSISession::getNextUniqueLUNID` @ `0x1000a901a` |
| Resize | `0x0F` | 4 bytes out: u32 BE, meaning not decoded | `ESASCSISession::resizeLUNS` @ `0x1000a7f78` |

- Delete is keyed by the **unique volume ID**, not the unit number macOS shows. Dashboard finds
  the volume object whose ID matches, unmounts it first (up to five tries, two seconds apart)
  and sends the delete even if unmounting failed.
- Where the unique ID is in the status pages this project already reads has not been matched
  up yet (`ESALUNInfo2Struct`, the object field at `+0x6a`). (Matched up in 11.26: management
  page `07`.)
- **Corrected in 11.26**, which reads these functions again and checks them against the 8D
  firmware: byte 4 of these three CDBs is zero, not the session's sequence number; the size is
  in bytes; and Dashboard sends no delete at all when it cannot find the volume (the `FF` above
  was a misreading).
- The Drobo's own log records a delete as event 500 and the space coming back as 501.

### 11.21 The 8D firmware image, first look (2026-11-17)

`release.Drobo8D.4-2-3.tdf`, 20 MB, read as a file only; not included in this repository.

- Not encrypted and not compressed as a whole. A `TDIH` header ("Data Robotics Firmware",
  product name "Gerty"), then two 32-bit little-endian ARM executables at `0x22c` and
  `0x2d815c`, VxWorks. Text is readable with `strings`. The first is the VxWorks kernel and
  board support; the second lies inside the first and is the array application, which runs as
  a VxWorks user process and keeps its symbol table (11.22).
- **A failed drive is "expunged"**, by the firmware's Error Policy Manager. Its messages name
  the limits that trigger it: hard error limit, hard error rate, short-timeout limit, drive
  start failures, and a limit on how often it power-cycled the slot. The numbers are not in
  the text. A drive that answers too slowly can be expunged without one bad sector **[inf]**.
- The expunge is remembered in the disk pack's own metadata ("EPM METADATA", zone 0), and the
  pack manager refuses the drive afterwards ("Refusing EXPUNGED slot", "EPM forces add
  refusal"). A drive with no Drobo header on it is "made available for re-use".
- The firmware has a command shell. Commands seen in its help text include `SmartStatus
  [0|1|2]`, `SMART-Test [slot]`, `SlotPowerCycle <slot> [epm]`, `state <manager>`,
  `PerfStats`, `metacheck int|ext`, and destructive ones (`esa wipeDisk <slot>`, an expunge
  command, `cleardisk`, deliberate crash). (An earlier version of this note gave
  `SystemState <manager>`: `SystemState` is the name of a section in the diagnostics file,
  not a shell command. See 11.22.)
- The shell has a path from the host: the firmware calls it `esaPassthroughCommand`, which
  is what Dashboard's `runEsaCommand` (system operation `0x0A`, 11.19) feeds. Framing decoded
  in 11.22. **Nothing sent.** (The firmware only lets it through in its lab mode: 11.24.)

### 11.22 The firmware shell over system operation `0x0A` (2026-11-17)

Static analysis only: Dashboard 3.6.1's service (`DDService64d`) and the 8D firmware 4.2.3.
**Nothing has been sent to a Drobo.** Firmware addresses below are in the second executable of
the `.tdf` (file offset `0x2d815c`, linked at address 0, symbols intact).

**Request and reply, from Dashboard** (`ESASCSISession::runEsaCommand` @ `0x1000a8bcc`, the
CDB builder `ESASystemOperationRequest` @ `0x1000c56e4`). **[obs]**

The CDB builder sets byte 6 from three flags: `0x40`, `0x20` and `0x01`. 11.14's `21` is
`0x20 | 0x01`; this command never sets `0x01`. The service takes the command text from the
request's `Params/ESACommand` string (`ESADevice::runEsaCommand` @ `0x100079912`) and sends
its bytes, with no terminating zero and no newline.

1. Send the command, data-out, length = text length:

       EA 10 00 0A <seq> 00 20 <len16 BE> 00      + ASCII command text

2. Read the answer, data-in, 2 KiB at a time, **with the same sequence number as step 1**
   (the counter is read once, as for the event log in 11.18):

       EA 10 80 0A <seq> 00 20 08 00 00           first read
       EA 10 80 0A <seq> 00 00 08 00 00           every later read

   Stop at the first chunk that comes back shorter than the one before it. The chunks joined
   together are the shell's text output; Dashboard treats it as a C string and cuts it at the
   first zero byte.

**What the firmware does with it** (`HAManager::systemOperation` @ `0x143958`, case `0x0A`
@ `0x144350`). **[obs]** unless marked.

- One command at a time. The data-out request creates a `DebugProxy` (stored at
  `HAManager + 0x92c`) and posts the text to the shell task's `/debugMsgQIn` queue
  (`DebugProxy::sendRequest` @ `0x12df18`). Each data-in request collects output
  (`DebugProxy::passData` @ `0x130b8c`), waiting for the shell task to finish if necessary,
  with a timeout taken from the diagnostics manager's settings. The proxy is released when the
  output has been handed out.
- A second data-out while a proxy exists is refused ("unexpected sendRequest (another esa
  cmd) REJECTED", status 9). A host must therefore always read every answer to the end. What
  happens to a proxy whose reads stop half way is not known.
- **The command length is not checked.** `sendRequest` copies as many bytes as CDB bytes 7–8
  say into a message field of about 256 bytes (the whole message is 308 bytes) and writes a
  zero after them. A host must keep commands well under 256 bytes.
- **Outside its internal "lab mode" the firmware refuses every command except two.**
  (Corrected 2026-11-17. This bullet first said the opposite, that only two texts were
  refused: the two branches after the `strncmp` calls @ `0x147188` and `0x1471a0` were read
  the wrong way round. Hardware then showed it, 11.24.) When `InLabMode()` is false, only a
  text starting with `proc uboot` or `enableBrickOverride` is passed on ("HAM: Not in Lab
  Mode, but allowing host command"). Any other text gets "HAM: Error: Host command not
  allowed, not in Lab Mode:" and status 16, and the command is released. What those two
  commands do was not traced, and this project does not send them. In lab mode every command
  runs, destructive ones included, and the handlers compare prefixes (`strncmp`), so a host
  must still restrict itself by exact match against a fixed list.
- The text is split into words and run by `ConsoleCommand::ExecuteCommand`, the same command
  table as the serial console (`DebugClass::esaPassthroughCommand` @ `0x15acc`). The word
  `resume` is treated specially.
- The diagnostics-file wrapper strings ("DataRobotics ... Data File Format") belong to a
  different branch of `passData`, the one used for the locked-diagnostics operation `0x07`.
  Whether a plain `0x0A` answer can ever carry that header was not traced **[inf: it does not]**.

**Slot numbers.** The shell counts slots from 0, and slot 8 is the SSD bay (the slot loops run
0–8). The event log does too: on this unit the 465 GiB SSD is logged as `SLOT_NUMBER="8"`. The
app shows `slot + 1`, so the app's bays 6 and 8 are shell slots 5 and 7. This also answers the
question left open in 11.17.

**Commands that could be allowed, with what each one does:**

| Command | Effect on 4.2.3 | Verdict |
|---|---|---|
| `state error` / `state error verbose` | `StateCommandHandler` @ `0x239f8` → `ErrorPolicy::Dump` @ `0xfac10`. Prints the expunge limits, each tracked drive's error counters (block errors, duplicates, region repairs, block rate, full, recovered, disk-start and short timeouts, flags), drives marked "NOT PHYSICALLY PRESENT", and global statistics. Takes a shared lock and reads memory only | Reads firmware memory only. This is where the counters behind an expunge are |
| `state dpm`, `state list` | Disk pack manager state; the list of manager names (`dpm dud perflog z0it catm defrag catmscan hlbat bfc bgsched zmdt rmdt dlbat error hrm locks sched mem ham spmm cal scrub pack dsm`, plus `all`) | Read only. `all` may be long |
| `SmartStatus [0\|1\|2]` | `getSMARTStatus` @ `0x12210` → `DiskManager::DumpSMARTStatus` @ `0x734a4`. For each slot set in the drive-ready bitmap it calls `SetSMARTOps(slot, 1)`, reads the SMART attributes, then `SetSMARTOps(slot, 0)`. Those are commands to the drive (an `ioctl` on the drive device) **[obs]**. The firmware's own health code does the same bracket (`DiskObject::Initialize`, `GetDrivesInfo`, `DiskPowerManager::Initialize`) **[obs]**. What `0` does on the drive is not decoded | Touches every ready drive. Drives that are not ready, such as expunged ones, are skipped **[inf]**. Not until every volume is copied off |
| `SMART-Test [slot]` | `runSMARTTest` @ `0x12d44` → `DiskObject::RunSMARTTestWithResults` @ `0x84d10`, which **returns 0 and does nothing** on this firmware. `RunSMARTTest` and `GetSMARTTestResults` are the same stub | No use; leave out |
| `SlotPowerCycle <slot> [epm]` | Power-cycles the slot. With `epm` it **first reports an error to the Error Policy Manager** (`ErrorPolicy::blockError`, type 10) | State-changing; never |

**How an expunge is recorded** (relevant to whether a drive can be taken back). **[obs]**

- `DiskPackManager::expungeLogicalDisk` @ `0xb2168` sets bit 31 of the drive's record flags
  (offset `0x0c`), next to a 32-byte reason string. No code was found that clears that bit.
- `ErrorPolicy::isDiskExpunged(slot)` @ `0xfeddc` maps the slot to the drive's identity
  through the drive WWN map, then checks that identity's error tracker. The expunge mark
  follows the **physical drive**, not the slot.
- When a drive is added (`DiskPackManager::hotPlug` @ `0xadee0`), the firmware reads its
  Drobo header (`discoverDis`), then refuses it if bit 31 of a record's flags word is set
  ("Refusing EXPUNGED slot"; the same bit as above **[inf]**). On the path for a drive that
  belongs to this pack it also asks `isDiskExpunged` **[inf]**; a yes is "EPM forces add
  refusal" and the drive is expunged again.
- A drive with no Drobo header is "made available for re-use" (`discoverAllDisRecords`).
  Whether the identity-keyed tracker also blocks a wiped drive on that path was not traced.
- No shell command was found that clears an expunge or a tracker.

### 11.23 The firmware shell in the driver (driver v0.30.0, 2026-11-17)

Everything below is how it is built, not what was observed. The first command sent to a Drobo
failed; see 11.24.

- The driver sends a shell command only when the app asks (Drives tab, Drive tools), never on
  its own, and only a text from a fixed table in the driver (`kShellCommands`). The app picks
  an entry by number; no caller can supply text. The firmware has no such list of its own in
  lab mode, and outside lab mode it refuses all of these (11.22, 11.24).
- Framing as in 11.22: the text data-out, then 2 KiB reads with the same sequence number. The
  first zero ends a chunk and a chunk that is not full ends the output. 256 KiB of output is
  kept; reads carry on past that (to 4 MiB) so that the Drobo's side is emptied.
- A read is given 120 s, because the Drobo answers it only when the command has run. With no
  answer the command is given up and status polling pauses for 2 minutes, as for the log.
- User-client selector 2 copies the output out, 4 KiB per call. `DroboStatus` gains
  `ShellState` (0 never, 1 running, 2 done, 3 failed), `ShellLength`, `ShellCommand`,
  `ShellSlot`, `ShellChunks`, `ShellSRB`, `ShellTruncated`; `CommandFormat` is 5.

| Table entry | Text | Sent when |
|---|---|---|
| 1, 2, 3, 4 | `state error`, `state error verbose`, `state dpm`, `state list` | asked |
| 5, 6 | `SmartStatus`, `SmartStatus 2` | asked and confirmed |
| 16 | `SlotPowerCycle <slot>` (never with `epm`) | confirmed, and the bay's light is red or flashing red, or the array is protected and at rest |
| 17 | `wipeDisk <slot>` | confirmed, and the bay's light is red or flashing red |
| 18 | `expungeDisk <slot>` | confirmed, the array is protected and at rest, and the bay is not failed |

"Protected and at rest" means none of the status flags bad disk, too many missing, no
redundancy, rebuilding, formatting (page `09`). The light is the bay status byte of page `03`.
The driver makes these checks itself from the pages it last read (`ShellPermitted`); the app
makes them too, to say why a button is off. The two pages must be newer than 15 s and read
since the last per-bay command; the check is repeated at the moment the command goes out, and
a command that fails it then is dropped (`ShellSRB` `0xFFFFFFFE`), never sent late; and a
minute must pass between two per-bay commands. That the shell's slot number equals the slot id in
page `03` is **[inf]** (both count from 0 and both put the SSD bay at 8), and the checks rest
on it; the app therefore keeps the per-bay commands off until a read-only command has been
answered, whose output lists the drives by slot. Slots 0 to 7 only: what these commands do to the
SSD bay was not traced. The three per-bay commands were added at the maintainer's request and
are outside safety rule 4's default.

The two commands not covered in 11.22, from the firmware. **[obs]**

- `wipeDisk <slot>` (`wipeDiskCommandHandler` @ `0x914bc`, help text "Clear DIS records to
  make disk look new"; the serial console form is `esa wipeDisk`, where `esa` is the kernel
  shell's prefix for this command table). Exactly one argument, slot 0 to 8. If the drive is
  a member of the pack it is expunged first and the handler waits for that. It then
  overwrites several ranges of the drive with a fill pattern and flushes the drive. Whether
  the Drobo then takes back a drive it had expunged is not known (11.22).
- `expungeDisk <slot>` (`expungeDiskCommandHandler` @ `0x21b1bc`, help text "PERMANENTLY
  remove disk and prevent use in other packs"). Needs a loaded disk pack; calls
  `DiskPackManager::expungePhysicalDisk` with the reason "COMMAND LINE EXPUNGE".

Left out on purpose: whole-array commands (`cleardisk`, `formatFAT32`, `createGPT`), the
deliberate crash commands, and `SMART-Test` (a stub on 4.2.3).

### 11.24 First shell command on the 8D: SRB response 4 (driver v0.30.0, 2026-11-17)

**Observed.** **[obs]** Drive tools, "Error counters, detailed" (`state error verbose`, table
entry 2), driver v0.30.0, firmware 4.2.3. Afterwards `DroboStatus` held `ShellState` 3,
`ShellSRB` 4, `ShellChunks` 0, `ShellLength` 0. The status pages kept answering (SRB response
1) and the volumes stayed mounted. v0.30.0 keeps one SRB value for the whole command, so this
does not say whether the Drobo turned down the command text or the first read of its output.
No other shell command has been sent.

**The request bytes were checked again and are not the cause.** Byte 6 was the suspect,
because it is the one field that differs from the system operations that work (`20` here,
`21` for blink and the dim level).

- The driver's three requests equal the layout in 11.22: `tests/shell_request_bytes.cpp`
  builds them with the functions the driver calls (`DroboShellCommandCDB`,
  `DroboShellReadCDB` in `DroboProtocol.h`), prints them and compares. For this command:

      EA 10 00 0A <seq> 00 20 00 13 00   + "state error verbose" (19 bytes), data-out
      EA 10 80 0A <seq> 00 20 08 00 00   first read, data-in
      EA 10 80 0A <seq> 00 00 08 00 00   later reads

- 11.22 equals Dashboard. **[obs]** `ESASCSISession::runEsaCommand` @ `0x1000a8bcc` calls
  `ESASystemOperationRequest`'s constructor @ `0x1000c56e4` with request type 1, operation
  `0A`, the sequence number, the three flags false, true, false, the length, the text and a
  zero for byte 9. The constructor sets byte 6 to `flag1 << 6 | flag2 << 5 | flag3` and byte 2
  to `80` only for request type 0. The length is the string's length
  (`ESADevice::runEsaCommand` @ `0x100079912`). The reads use type 0, flags false,
  first-read, false, and length `0x800`.
- **The firmware does not read byte 6 for this operation.** **[obs]** In the user-process
  image, `HAManager::systemOperation`'s case `0A` reads CDB bytes 2 (direction), 7–8 (length)
  and 9, and `DebugProxy::passData` reads bytes 7–8. Of the management handlers only
  `GetUserEventLog` (operation `22`) reads byte 6 (@ `0x142d40`). In the kernel image,
  `processESAManagementCommand` reads the opcode and byte 3 only. Sending `21` in place of
  `20` would change nothing, so the driver keeps Dashboard's `20`.

**Where SRB response 4 comes from.** **[obs]** unless marked. The firmware's kernel image (the
first executable of the `.tdf`, linked at `0x1000000`) handles every passthrough request in
`processESAManagementCommand` @ `0x1293e94`. It copies a data-out payload from the host,
passes the request to the user process as three messages (a 44-byte command block, the
16-byte CDB, the payload), waits for a 44-byte answer, and for data-in copies the reply back.
Its reply is SRB response 1; `12` when a data-in moved a different count than was asked for;
and, when its error flag is set, **zero bytes and SRB response 4** (`12` for a data-out over
`0x8000` bytes or with no transfer buffer). The error flag is set when:

1. the request's flags have neither direction bit (`0x10000`, `0x20000`);
2. the copy of a data-out payload moves fewer bytes than asked ("Failed to transfer the SGL");
3. one of the three messages cannot be queued;
4. the user process answers with an error ("ERROR RETURN from HRM"), which is what a
   non-zero status from `HAManager`'s handler becomes **[inf: the mapping in
   `HRManager::putResponse` was not traced]**;
5. for data-in, the follow-up message does not arrive, or the flags have neither buffer-mode
   bit (`0x08`, `0x10`: "Unknown transfer type"), which is the SRB response 4 seen in 11.5.

A data-out of 16 bytes or fewer only logs a warning, which is why blink's single byte goes
through. In direct-buffer mode the address comes from the request's `+0x28` field and the
length from the transfer length (`mvBuildIdmaDescriptorChain` @ `0x12a1580`), so the 19
bytes of text are fetched the same way as blink's one byte.

**What makes the `0A` handler itself return an error** (user-process image, case `0A` @
`0x144350`). **[obs]**

- The command text while an earlier command is still open: status 9 (11.22).
- The two message queues cannot be opened (`DebugProxy::Init` @ `0x128a50`): status 14.
- A text the firmware does not allow, which outside lab mode is every text but two (11.22):
  status 16. **This is what happened**, see the live run below.
- A read when the shell hands over no output within **30 seconds** (the wait in
  `DebugProxy::passData` @ `0x1310b0`, `DiagnosticsManager`'s default at `+0x0c`), or the
  queue read fails: status 16. After an error on a read the firmware releases the command
  (@ `0x147374`), so a failed command does not block the next one.
- The shell task's own reply always carries status 0 (`DebugClass::RequestHandler` @
  `0x165c8`, the store @ `0x17230`): an unknown command or a bad argument comes back as text,
  not as an error. Two shell threads (`tDebug1`, `tDebug2`) are started unconditionally
  (`DebugClass::Initialize` @ `0x1ea9c`), in and out of lab mode.

**Live run with driver v0.30.1 (2026-11-17, 02:35).** **[obs]** The maintainer activated
v0.30.1 and ran Drive tools commands; the registry was read after `state dpm` (entry 3) and
again after `SmartStatus 2` (entry 6). Both times: `ShellStep` 1, `ShellSRB` 4,
`ShellSCSIStatus` 0, `ShellTransferred` 0, `ShellElapsedMS` 5. The Drobo turns down the
**command text**, at once.
The volumes remounted read-only afterwards and the status pages kept answering.

**Cause: the shell is closed outside lab mode.** That result ruled out the 30-second wait
and the reads, and sent the analysis back to the text check in case `0A` (@ `0x147168`).
**[obs]** `InLabMode()` @ `0x314084` asks the kernel once (system call `0x1a52`) and keeps
the answer. When it is false, the text is compared with `proc uboot` (10 bytes) and
`enableBrickOverride` (19 bytes); a text that starts with neither is refused with status 16,
which reaches the host as SRB response 4 with no data after a few milliseconds. `state error
verbose`, `state dpm`, `SmartStatus` and the per-bay commands are all refused this way, so
**none of the Drive tools commands can work on a Drobo that is not in lab mode**, and this
unit is not. What sets lab mode is traced in 11.25 (it is the VxWorks ED&R debug flag, not host-
settable). 11.22 had this check the wrong way round and is corrected.

So the first failure (v0.30.0) was the same refusal, and nothing a shell command would have
done has happened on the Drobo: no command reached the shell. **[inf]**

**A rule for hosts.** **[obs]** A `0A` read (byte 2 = `80`) when no command is open is not
refused. The firmware logs "unexpected passData when expect sendRequest (new esa cmd)" and
then treats the request as a new command (@ `0x1483ac`, falling into `0x14709c`), taking the
"text" from where a data-out payload would be. A host must never send a `0A` read except
after the text was accepted, with the same sequence number, and must not send reads to
"drain" a command it is unsure about. The driver sends reads only after an accepted text and
stops at the first request that fails.

**Driver v0.30.1** sends nothing new. It records, for the request of a shell command that
was answered last: `ShellStep` (1 the command text, 2 a read), `ShellSCSIStatus`,
`ShellTransferred` and `ShellElapsedMS`, next to `ShellSRB`. A request the Drobo never
answers keeps `ShellSRB` `0xFFFFFFFF` and now also its step. The app shows these under Drive
tools when a command fails, `drobo console` prints them, and `drobo console --json` returns
them. This is what showed the refusal above. How to read a failure:

| `ShellStep` | `ShellElapsedMS` | Meaning |
|---|---|---|
| 1 | a few | The text was turned down: not in lab mode (seen), or the copy from the host failed, or the Drobo has a command open |
| 2 | about 30 000 | The text was accepted and the shell printed nothing in 30 s |
| 2 | small | The text was accepted and the read failed at once |

### 11.25 What "lab mode" is: the firmware's VxWorks ED&R debug flag (2026-11-17)

Static analysis of both firmware images; nothing was sent to the Drobo for this. **[obs]**
unless marked. This answers the question 11.24 left open — what makes `InLabMode()` true —
and settles whether Drive tools can ever work on a stock 8D.

**Lab mode is the operating system's own debug state, not a Drobo setting.** The firmware
runs VxWorks, and "lab mode" is VxWorks's ED&R (Error Detection and Reporting) **system debug
flag**. The kernel's help text for it is VxWorks's own, word for word: "This command provides
access to the system debug flag. This flag indicates whether the system is in 'debug' (also
known as 'lab') mode, or in 'field' (or 'deployed') mode." The kernel logs "Setting ED&R
state to Lab mode" and "Setting ED&R state to Deployed mode", and in lab mode "LABMODE - RTP
suspended and available for debugging": when a user process crashes, the OS freezes it for a
debugger instead of restarting it. A production unit ships in deployed (field) mode.

**How the firmware reads it.**

- `InLabMode()` in the user process (@ app `0x314084`) asks the kernel once, caches the
  answer, and returns it. The query is VxWorks system call number `0x1A52`
  (`syscall(..., 0x1A52)`); the kernel side is `getDebugMode` (@ kernel `0x107dce4`), next to
  `setDebugMode` (@ `0x107dc88`), `getBoardDebugModeEnabled` and the ED&R fatal-policy suite
  (`edrRtpFatalPolicyHandler`, `usrEdrInit`, ...). The ED&R state lives in a persistent memory
  region (`edrShow` reads the same region's error log).
- Case `0A` of `systemOperation` calls `InLabMode()` first (11.24). Deployed mode means every
  shell command but `proc uboot` and `enableBrickOverride` is refused with "Host command not
  allowed, not in Lab Mode" and status 16, which the host sees as SRB response 4.

**It cannot be turned on from the host, and there is no reason to.** **[inf]** unless noted.

- The host side is read-only: `InLabMode()` only reads, and the `labmode` text command in the
  user process (`ReportLabMode` @ app `0x33b078`) only **displays** the flag and the build's
  feature list ("LABMODE is ENABLED/DISABLED"). Neither sets it. **[obs]**
- Setting ED&R mode is `setDebugMode` / VxWorks `edrSystemDebugModeSet`, a **kernel** routine.
  The firmware exposes a kernel shell only on the board's serial console (the `uart16550`
  driver is present), which this host protocol never reaches: the `0A` shell runs the
  **user-process** command table, a different and lower-privileged shell. No management
  request, and nothing in `DDService64d`, changes ED&R mode.
- So enabling it would mean opening the enclosure, attaching to the board's UART, and putting
  the live OS into a debug state where a crashed process hangs instead of recovering — the
  opposite of what you want under an array with no redundancy. Not a path worth taking for
  data rescue.

**Conclusion.** The firmware-shell Drive tools (`state error`, `SmartStatus`, and the per-bay
`SlotPowerCycle` / `wipeDisk` / `expungeDisk`) are usable only on an engineering unit left in
ED&R lab mode. On Joe's 8D, and any retail 8D in deployed mode, they cannot work, and no safe
host-side change makes them work. The SMART-ish data the Drobo does publish without the shell
(per-drive temperature, error count, life remaining; slot page `35`, 11.9/11.12) is the
most these commands could have added for drive health, and that path already works. Bumping or
recovering a drive has no host route at all; a physical reseat is the only option.

### 11.26 Volume create, delete and reset: Dashboard and firmware, then the driver (driver v0.31.0, 2026-11-21)

Static analysis of Drobo Dashboard 3.6.1's service (`DDService64d`, x86_64) and of the 8D
firmware 4.2.3 (the second executable of the `.tdf`, as in 11.22). **[obs]** unless marked.
What was then sent to a Drobo is at the end, under "On hardware".

**How Dashboard resets ("erases") a Drobo.** The service command `eCmdReset` reaches
`ESABlockDevice::Reset()` @ `0x10006b4e8`. It calls the device's `formatESA` (vtable slot
`+0x48`, `ESADevice::_formatESA` @ `0x100074ffc`), which unmounts the volumes of every unit
(`ESABlockLUN::unmountVolumes`) and then calls the session's `formatESA` (session vtable slot
`+0x20`, `ESASCSISession::formatESA` @ `0x1000a7e7c`). That is one call:
`sendSystemOperation(0x02)`, the plain form of 11.14, the same one blink uses.

    EA 10 00 02 <sequence> 00 21 00 01 00        + one zero byte, data-out

`Reset()` then drops the device from the service's device list. There is no second request,
no challenge and no confirmation on the wire: the confirmation users remember was Dashboard's
own dialog. The trace string in the firmware names the operation `ESA_SYSOPID_FORMAT_ESA`.

**What the firmware does with operation `0x02`** (`HAManager::systemOperation` @ `0x143958`,
jump table at `0x1439b4`, case `0x02` @ `0x143eb0` → `HAManager::cleardiskArray()` @
`0x12d888`):

- reads three settings out of its flash configuration (`demomode`, `scalefactor`,
  `maxlunsize`), deletes the configuration file (`FlashConfigData::DeleteConfigFile`) and
  writes those three back. Everything else in the configuration goes: name, options,
  thresholds **[inf: from the file being deleted]**;
- if no drives are present it logs "no disks, just clearing flash";
- otherwise it creates the file `/bd0/FormatOnStart` on its boot device, a marker that makes
  the next start-up format the disk pack **[inf: from the name]**;
- turns off the battery-backed RAM (`SystemManager::psramBatteryPowerOff`) and schedules
  `HAManager::ClearDiskReboot` one second later, which restarts the unit
  (`SystemManager::Reboot`).

So the request is answered first and the erase happens during the restart that follows. It
is the same thing the shell command `cleardisk` does (`cleardiskCommandHandler` @ `0x12dbec`).
Every drive in the unit at that moment is formatted, failed ones included **[inf]**.

**The four requests.** The CDB is built by `ESASystemOperationCDB`'s constructor @
`0x1000c5838`: byte 2 is `80` for a read, byte 3 the operation, byte 4 an argument of the
caller's, byte 6 three flags (`0x40`, `0x20`, `0x01`), bytes 7–8 the length.

| What | CDB | Data | Dashboard | Firmware case |
|---|---|---|---|---|
| Reset | `EA 10 00 02 <seq> 00 21 00 01 00` | 1 zero byte out | `ESASCSISession::formatESA` @ `0x1000a7e7c` | `0x143eb0` |
| Next unique volume ID | `EA 10 80 20 00 00 21 00 02 00` | 2 bytes in: u16 BE | `ESASCSISession::getNextUniqueLUNID` @ `0x1000a901a` | `0x145200` |
| Create a volume | `EA 10 00 12 00 00 21 00 0C 00` | 12 bytes out, below | `ESABlockDevice::CreateLUN` @ `0x10006654e` | `0x144d94` |
| Delete a volume | `EA 10 00 13 00 00 21 00 04 00` | 4 bytes out, below | `ESABlockDevice::DeleteUniqueLUN` @ `0x100064008` | `0x145594` |

Byte 4 is **zero** for the three volume requests: `CreateLUN` and `DeleteUniqueLUN` build the
CDB themselves with a zero there, and `getNextUniqueLUNID` passes zero. Only requests that go
through `sendSystemOperation(unsigned char)`, reset among them, carry the session counter.
(11.20 said all four carry it; that was wrong.)

*Create, 12 bytes:*

| Offset | Type | Dashboard | Firmware |
|---|---|---|---|
| 0 | u64 BE | the request's `Size` | size in **bytes**: it shifts right by 9 and subtracts 1 to get the last block number |
| 8 | u8 | low byte of the request's `Flags` | bit 0 is handed to `HRManager::createLun` as its last argument and on to `CATLookupTable::createLun`; meaning not decoded **[unk]** |
| 9 | u8 | always 0 | when not zero, the firmware marks its USB transport inactive after a successful create (the host is made to reconnect **[inf]**) |
| 10 | u16 BE | the unique volume ID | the new volume's unique ID |

`HRManager::createLun` @ `0x2de6f8` refuses a size above its limit ("Requested LUN too big",
status 16) and a create beyond the volume count; on success it logs "HRM:createLun: created
LUN #n" and posts a user event with `LUN_NUMBER` and `SIZE`. The unit number is chosen by the
firmware, not by the host.

*Where the unique ID comes from.* For most models Dashboard first asks the Drobo (operation
`0x20`) and uses the answer. The firmware's handler returns a 16-bit counter kept with the
disk pack's volume table (`CATManager` structure, offset `0x17c`) and adds one to it, so the
read is not free of side effects: each one uses up an ID. For other models Dashboard counts on
its own, from the largest "next available ID" it has seen in the volume list. Which of the two
it does for an 8D depends on a feature bit of the device object (`+0x1e5`, bit 1) that was not
traced **[unk]**. The 8D's firmware has the `0x20` handler, so this driver asks.

*Delete, 4 bytes:* u16 BE unique volume ID, u8 unit number, u8 which, when not zero, makes the
firmware mark its USB transport inactive afterwards (Dashboard sends 0). The firmware calls
`HRManager::deleteLun(unit, uniqueID)` @ `0x2d6c68`. Dashboard looks the unit number up from
the unique ID, first among its volume objects, then in its cached volume list; if it finds the
ID in neither **it sends nothing**. Before sending it takes the unit's volumes offline
(`ESABlockLUN::offlineUnwantedVolumes`) and sends the delete even if that failed.

Resize (operation `0x0F`, 11.20) is still not decoded and not implemented.

**The volume list: management page `07`** (`ESALUNInfo2`; the firmware's
`HAManager::GetLunInfo2` @ `0x1323f0`). MODE SENSE as for every other page. After the 4-byte
header comes a count byte at offset 4, then one 19-byte record per volume
(`ESALUNInfo2Struct::parse` @ `0x10009e11c`, names from its `print`):

| Offset in record | Type | Field |
|---|---|---|
| 0 | u16 BE | length of the rest of the record (`0x0011`) |
| 2 | u8 | LUN ID: the unit number |
| 3 | u64 BE | total capacity, bytes |
| 11 | u8 | partition scheme |
| 12 | u8 | partition count |
| 13 | u8 | format type |
| 14 | u16 BE | unique ID |
| 16 | u16 BE | next available ID (the counter operation `0x20` hands out) |
| 18 | u8 | flags; bit `0x08` is set from a per-volume flag in lab mode only |

Dashboard's parser accepts this page only when byte 1 of the header reads `04`, although it
asks for sub-page `07`. What the 8D puts there is under "On hardware".

**The config page `01` in full** (`ESAConfigurationInfo::parse` @ `0x10009bc4c`), 28 bytes with
the header. The driver asked for 15 until v0.30.1; the page's own length field says `0x18`.

| Offset in page | Type | Field | On the maintainer's 8D |
|---|---|---|---|
| 4 | u8 | maximum slot count | 9 |
| 6 | u8 | maximum LUN count | 16 |
| 7 | u64 BE | maximum LUN size, bytes | `0x400000000000`, 64 TiB |
| 16 | u32 BE | demo mode | not read before v0.31.0 |
| 20 | u32 BE | scale factor | not read before v0.31.0 |
| 24 | u32 BE | read-only mode | not read before v0.31.0 |

**In the driver (v0.31.0).** Design and safety model are in
[05-volume-management.md](05-volume-management.md). In short:

- Page `07` is read with the other pages (key `Volumes` under `DroboHealth`), sized from the
  config page's LUN count. A Drobo that refuses it loses volume management and nothing else.
- User-client selector 3 takes one volume command: create (size), delete (unit and unique
  ID) or reset. The driver refuses it unless the caller passes a fixed confirm value **and the
  Drobo's own serial number**, no block I/O is in flight or queued, and, for create and
  delete, the volume list was read within the last 15 seconds and agrees with the request
  (the volume to delete is listed with that unit and ID; there is room for another volume;
  the size is whole blocks and within the config page's limit). The checks run again at the
  moment the destructive request goes out, and a request that fails them then is dropped.
- Create is two requests: `0x20`, then `0x12` with the ID just read. If the ID comes back as
  one a listed volume already has, the create is not sent. The flags byte and byte 9 are
  always 0.
- `DroboStatus` gains `VolumeState` (0 never, 1 running, 2 done, 3 failed), `VolumeCommand`,
  `VolumeStep` (1 the ID read, 2 the change itself), `VolumeSRB` (`0xFFFFFFFF` no answer in
  two minutes, `0xFFFFFFFE` dropped by the driver unsent, `0xFFFFFFFD` ID in use),
  `VolumeSCSIStatus`, `VolumeUnit`, `VolumeUniqueID`, `MaxVolumes`, `MaxVolumeBytes`,
  `VolumeListFailed`, `LUNRescans`; `CommandFormat` is 6.
- After a create or delete the Drobo answers, the driver reads the LUN table in BAR1 again
  every 4 seconds for up to a minute. When it has changed, and no block I/O is in flight, the
  driver takes the new table and announces its SCSI target again, with writing off for every
  unit that changed. Whether the 8D changes that table without a restart was not known when
  this was written (drobo-utils has a status bit `0x4000`, "new volume available after
  restart").
- `tests/volume_request_bytes.cpp` builds all four requests with the driver's own functions
  and compares them with the table above.

**On hardware.** Nothing in this section had been sent to a Drobo when it was written. Results
are added below as each step is run on the maintainer's 8D (firmware 4.2.3), in the order of
the test plan in 05-volume-management.md.

## 12. Open questions that need the hardware

0. ~~What puts the 8D in "lab mode" so the firmware shell accepts commands.~~ Answered in
   11.25: it is the VxWorks ED&R system debug flag, set only from the board's serial console,
   not from the host. The Drive tools cannot work on a deployed unit.

1. ~~Which config-space BARs back "device memory 0/1".~~ Answered in section 11: BAR0 and BAR2.
2. ~~Interface Version.~~ Answered in 11.1: version 6.
3. ~~Contents of both interrupt tables.~~ Answered in 11.1.
4. Whether the device accepts a host that never triggers the unreferenced In[1]/In[2]/In[6].
5. SysControl request flags, and the unnamed capability words `0x28`–`0x3F`.
6. ~~32-bit DMA through the Apple silicon DART.~~ Answered in 11.3: it works.
   Original note: The kext shipping an arm64e slice suggests Drobo ran this on
   M1, but that is not proof.
7. Volume management (11.26): what bit 0 of the create flags byte does; which way Dashboard
   gets the unique ID for an 8D; whether the LUN table in BAR1 changes without a restart after
   a create or delete; what a reset does to drives that were already marked failed.

Items 2–3 are answered by a read-only probe: map both BARs, read the `DroboPort` header,
capabilities and tables, and log them. That needs the host-BAR-ready write first (the only
write involved), because the firmware does not publish `DroboPort` until then **[inf]**.
