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
   headers and layouts) and run it in `build.yml`.
3. **Verify the write path** [driver, needs hardware]. Enable Allow writes on a backed-up
   volume, run Test Writing, then copy a few GB and compare checksums after eject and remount.
   Record the result in protocol notes section 11.
4. **Verify cache-flush forwarding** [driver, needs hardware]. The Flushes counter should rise
   with zero errors after writes and an eject; a timeout must disable forwarding, not hang I/O.
5. **Verify sleep/wake** [driver, needs hardware]. Sleep and wake with volumes mounted; I/O
   resumes, Wakes increments, nothing is force-ejected.
6. **Verify Rename, Shut Down, Settings; fix Blink** [driver, app, needs hardware]. Formats
   come from drobo-utils. **Blink is turned off**: as sent it made the 8D stop responding and
   restart (protocol notes 11.8). Do not re-enable it, and do not test Shut Down (the same
   vendor command with another sub-code), until the 8D's format is confirmed from Drobo
   Dashboard (item 1). Never test either on a unit that is rebuilding. Settings only on a
   healthy unit.
7. **General interpreter for the doorbell tables** [driver, protocol]. The driver hard-codes the
   8D's doorbell values and only checks them against the device's tables. Implement the
   and/or/xor/set/none interpreter from protocol notes section 6 so other firmware and models
   can work.
8. **Second PCI ID `4452:5570`** [driver, needs hardware]. Add the personality behind the same
   safety checks. Needs an owner of such a unit.
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
12. **Drobo volume icons in Finder** [app, driver, needs hardware]. Drobo Dashboard gave mounted
    volumes a Drobo-styled disk icon with a light bar showing how full the volume is. Two routes
    to investigate: a custom `.VolumeIcon.icns` written to the volume (needs write access, so not
    possible on the read-only default), or an icon the driver supplies for its disks. Decide
    which is feasible under DriverKit before building either.
13. **Telemetry the dashboard cannot show yet** [protocol, needs hardware]. Temperature, fan
    speed, uptime, power state, hot data cache, disk pack status and data integrity have no
    documented page (see the dashboard table in [03-coverage.md](03-coverage.md)). Depends on
    item 1. Also decode what is already polled but unused: the device clock (settings page), the
    protocol version and the config page's LUN limits, and work out the slot record's "short
    identity" field and trailing u32 from a hardware dump.
14. **Events and performance history, next steps** [app]. Both tabs exist. Still open: keep
    performance history across app restarts, add latency over time (the driver publishes only
    running totals, so the app must difference them), and export the event log.
