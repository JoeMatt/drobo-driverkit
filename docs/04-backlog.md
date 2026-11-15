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
6. **Verify Blink, Rename, Shut Down, Settings** [driver, app, needs hardware]. Formats come
   from drobo-utils. Blink first; Settings only on a healthy unit.
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
