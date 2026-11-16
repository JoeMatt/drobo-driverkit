# Backlog

Open work, written so each item can become one issue and one pull request. Labels in brackets:
`needs hardware` means a maintainer must run it on a Drobo 8D; the rest need no hardware.
Rules for all of it are in [AGENTS.md](../AGENTS.md); current status is in
[03-coverage.md](03-coverage.md).

1. **Reverse-engineer Drobo Dashboard 3.6.1** [protocol]. It has not been analysed; the app's
   features come from the kext and drobo-utils. Find how Dashboard issues SCSI commands, list
   every CDB and MODE page it sends with payload layouts, and add that as a new section of the
   protocol notes. This decides coverage of restart, LED brightness, volume
   create/delete/resize, SSD cache management, alert thresholds and diagnostics. Documentation
   only: no destructive commands in the driver.
2. **Unit tests for the management page decoders** [app, good first issue]. `DroboMonitor.swift`
   has no tests. Add a test target with fixture bytes per page (protocol notes 11.5 gives real
   headers and layouts; a diagnostics file from the maintainer gives whole pages) and run it in `build.yml`.
3. **Verify the write path** [driver, needs hardware]. Enable Allow writes on a backed-up
   volume, run Test Writing, then copy a few GB and compare checksums after eject and remount.
   Record the result in protocol notes section 11.
4. **Verify cache-flush forwarding** [driver, needs hardware]. The Flushes counter should rise
   with zero errors after writes and an eject; a timeout must disable forwarding, not hang I/O.
5. **Verify sleep/wake** [driver, needs hardware]. Sleep and wake with volumes mounted; I/O
   resumes, Wakes increments, nothing is force-ejected.
6. **Verify Blink, Restart, Shut Down, Rename, Settings** [driver, app, needs hardware].
   Blink, Restart and Shut Down use Drobo Dashboard's own framing since v0.27.0 (protocol notes
   11.14); the earlier framing hung the 8D. Try Blink first. Restart and Shut Down only on a
   unit that is not rebuilding. Then: LED brightness (find the valid range of the dim level,
   operations `18`/`21`) and the SSD cache switch (map the feature bits of options page `31`,
   probably from the Dashboard app's own binary).
7. **General interpreter for the doorbell tables** [driver, protocol]. The driver hard-codes the
   8D's doorbell values and only checks them against the device's tables. Implement the
   and/or/xor/set/none interpreter from protocol notes section 6 so other firmware and models
   can work.
8. **Test the second PCI ID `4452:5570`** [driver, app, needs hardware]. The personality is in
   since v0.24.0, behind the same bring-up checks, and has never met a real unit. Needs an owner
   of a 5D, 5D3 or Mini: read-only first, a diagnostics file, then fix what the app assumes
   about the 8D (bay numbering and the SSD bay's slot id).
9. **Forward read-only passthrough CDBs from the SCSI layer** [driver, protocol]. The kext
   passed INQUIRY, MODE SENSE and unknown opcodes to the device; the dext answers them itself.
   Needs the SGL buffer mode (flag `0x10`) for the task's data buffer.
10. **Real auto-update** [app]. Blocked on Apple granting distribution entitlements. Then:
    integrate an updater with release and nightly channels and add a nightly build workflow.
11. **More than one Drobo at a time** [app]. The driver keeps all state per device, so each
    attached unit should get its own controller instance (never tried with two units). The app
    and the `drobo` command read only the first controller they find, and match volumes to
    units by LUN number alone. Key everything by controller (registry entry ID or serial) and
    add a device switcher to the dashboard and a `--device` option to the command.
12. **Finder icons for read-only volumes** [driver, research]. The app can now put a Drobo-style
    icon with a fullness bar on a volume that allows writes (the icon is a file on the volume,
    as Drobo's own software did it). Read-only volumes still get the generic icon. Drobo's kext
    supplied device icons from its own bundle; find out whether a DriverKit driver can supply an
    `IOMediaIcon` for its disks.
13. **Verify the optional pages on hardware** [driver, app, needs hardware]. Pages `35`
    (drives), `33` (system), `34` (performance), `36` (power), `37` (fan) are implemented behind
    "Read drive and system details". On the 8D (protocol notes 11.12, 11.13) `35`, `33` and
    `34` answer and `36` and `37` are refused. Still open: the units of page `34` (capture it
    under load), the per-drive disk state values, why the 8D reports drive temperature as 0,
    and whether another model answers the fan and power pages. Still undecoded: `11` disk
    pack, `38` controller card.
14. **Events and performance history, next steps** [app]. Both tabs exist. Still open: keep
    performance history across app restarts, add latency over time (the driver publishes only
    running totals, so the app must difference them), and export the event log.
15. **USB Drobos in the dashboard** [driver, research, needs hardware]. Settled by analysis
    (protocol notes 11.11): Drobo's software needed its own kernel driver to send management
    commands to USB units, so an app alone cannot do it. The route is a second driver extension
    on `SCSIPeripheralsDriverKit` that matches the Drobo's INQUIRY identity and takes over the
    disk, which means it carries all of that disk's I/O. That needs its own entitlement, an
    owner of a USB unit to test with, and the same read-only-first discipline as this driver.
    Not started.
16. **The Drobo's own event log** [driver, needs care]. Found by analysis, not yet sent
    (protocol notes 11.16). It is not a management page: Dashboard reads it with system
    operation `0x22`, in 32 KiB chunks. The driver's passthrough data area is 4 KiB, so this
    needs a larger DMA buffer, a chunk loop and a way to hand the text to the app. It is a
    vendor command this driver has never sent; try it first on a Drobo that is protected, not
    one that is rebuilding. The app side (84 event names and severities) is straightforward.
17. **Drive history, next steps** [app]. Recorded only while the app runs. Still open: per-bay
    detail view, export, and using the Drobo's own log (item 16) to fill the gaps.
