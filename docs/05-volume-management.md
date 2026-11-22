# Volume management: create, delete, reset

Spec for driver v0.31.0. The wire protocol, with its evidence, is in
[protocol notes 11.26](01-protocol-reverse-engineering.md); status is tracked in
[03-coverage.md](03-coverage.md). This page says what was built and why it is shaped the way
it is.

Until v0.30.1 these were out of scope by decision (AGENTS.md safety rule 4). The maintainer
reversed that for these three operations in November 2026: a Drobo with failed drives and its
contents copied elsewhere can only be put back to use by resetting it, and Drobo Dashboard no
longer runs on current Macs. Firmware update, resize and anything per-drive stay out of scope.

## What each operation does

| Operation | Sent to the Drobo | Effect |
|---|---|---|
| Create a volume | system operation `0x20` (read the next unique volume ID), then `0x12` (size in bytes, flags 0, that ID) | A new, empty logical unit. Nothing existing changes. Drobo volumes are thin: the size is what the Mac sees, not space set aside |
| Delete a volume | system operation `0x13` (unique ID, unit number) | That unit and everything stored in it are gone. The space returns to the pool |
| Reset | system operation `0x02`, one zero byte | The Drobo deletes its settings, marks its disk pack to be formatted, and restarts. Every drive in it is erased, failed ones included |

Not built: resize (operation `0x0F` is not decoded), renaming a volume, formatting (that is
Disk Utility's job once the unit allows writes).

## Safety model

The rule from AGENTS.md stands: the driver holds the checks, because nothing the app or the
command gets wrong may reach the hardware. Three layers, each of which refuses on its own.

**1. The driver** (`DroboSCSIController::VolumeCommand`, `VolumePermitted`):

- The caller must pass a fixed confirm value and **the Drobo's serial number**, which the
  driver compares with the one it read from the device. A caller that does not know which
  Drobo it is talking to cannot erase it.
- Nothing is sent while block I/O is in flight or queued.
- Nothing is sent while another management command, a log read or a shell command is running.
- Create and delete need a volume list (page `07`) read in the last 15 seconds. Delete needs a
  listed volume with exactly that unit number and unique ID. Create needs room for another
  volume and a size that is a whole number of 512-byte blocks, no larger than the config
  page's maximum.
- The same checks run again at the moment the destructive request goes out. A request that
  no longer passes is dropped, not sent late. A volume list is used for one command only.
- Create never sends the create if the ID the Drobo hands out is one a listed volume has.
- No retry. An unanswered command is reported as "not known whether it was carried out".
- A new or changed unit is never writable until the person turns Allow writes on for it.

**2. The shared layer** (`DroboMonitor.volumeBlocker`, used by the app and the command):

- Refuses while **any** Drobo volume is mounted, for all three operations. The driver cannot
  see mounts, only I/O, and after a create or delete it announces its disks again, which
  would pull a mounted volume away.
- Refuses with an older driver (`CommandFormat` below 6), without a volume list, or for a unit
  the list does not have.

**3. The person**:

- App: a sheet that says what will happen and keeps its button off until the Drobo's serial
  number has been typed into it.
- Command: without `--yes-really` it prints what it would do and sends nothing (exit 2). With
  it, the serial number must be given with `--serial` or typed at the prompt.

What these layers do not cover: a volume in use by a process that has the raw disk open but
no I/O in flight at that instant, and anything another Mac is doing over a second cable.

## App

- **Volumes tab**: `New Volume…` in the button row; `Delete…` on each volume's row. Both are
  off while any Drobo volume is mounted.
- **Advanced tab → Tools**: `Reset Drobo…`.
- All three open the same confirmation sheet (`VolumeConfirmSheet`). For a new volume it has a
  size field (`16TB`, `500GB`, `max`; binary units, as the Drobo counts) that defaults to the
  largest size the Drobo allows.
- The outcome appears in the message line, from the driver's `VolumeState`.

## Command

```
drobo volumes                                   # now with the Drobo's ID for each volume
drobo volume create [--size 16TB|500GB|max] [--serial <serial>] [--yes-really]
drobo volume delete <unit> [--serial <serial>] [--yes-really]
drobo reset [--serial <serial>] [--yes-really]
```

Exit status: 0 done, 1 refused or failed, 2 nothing sent because `--yes-really` was missing.
`--watch` is ignored for these. A volume that is literally named `create` or `delete` can no
longer be looked up by name with `drobo volume <name>`; use its unit number.

## After each operation

- **Create**: the driver looks at the Drobo's LUN table for up to a minute and announces the
  disks again when the new unit shows up. If it does not, restart the Drobo. Then turn on
  Allow writes for the unit and erase it in Disk Utility (GUID partition map, APFS or Mac OS
  Extended).
- **Delete**: the same table check; the unit's disk disappears.
- **Reset**: the Drobo restarts and formats its drives, which takes several minutes. The
  driver sees it leave and come back as for any restart.

## Test plan

Without hardware (runs in CI):

1. `tests/volume_request_bytes.cpp`: the four requests byte for byte against the protocol
   notes, and the volume list decoder (count, fields, truncated and empty pages).
2. The unsigned build.

On a Drobo whose contents are expendable, in this order, recording each result in protocol
notes 11.26. Stop at the first step that does not behave as described.

1. Install v0.31.0 and activate it. `drobo volumes` shows an ID for each unit; `drobo
   diagnostics` has `Volumes` under `DroboHealth` and a 28-byte `Config`. Everything that
   worked before still does. (Reads only.)
2. Refusals, nothing sent: each command without `--yes-really`; with a wrong serial; with a
   volume mounted.
3. `drobo volume delete <unit>` on one unit. Expect response 1, the unit gone from `drobo
   volumes`, event 500 in the Drobo's log.
4. `drobo reset`. Expect response 1 or the Drobo disconnecting, a restart, and afterwards an
   empty or freshly formatted pack.
5. `drobo volume create`. Expect response 1 and a new unit, at once or after a restart.
6. Allow writes on the new unit, erase it in Disk Utility, copy a file, eject, remount, compare.
