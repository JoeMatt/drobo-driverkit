## What this changes

<!-- One or two sentences. Link the issue. -->

## Evidence

<!-- For protocol or driver behaviour: kext function + offset, drobo-utils reference, or a
     hardware observation from docs/01 section 11. -->

## Verification

- [ ] Unsigned build passes (`xcodebuild … CODE_SIGNING_ALLOWED=NO build`)
- [ ] Run on a Drobo 8D by: <!-- name, or "nobody yet" -->

What a maintainer should test on hardware, step by step:

1.

## Checklist

- [ ] `docs/03-coverage.md` updated if a feature's status changed
- [ ] `project.yml` version bumped if the driver changed
- [ ] New MMIO writes / device commands listed in the header of `DroboSCSIController.cpp`
- [ ] Any new queue or dispatch source is cancelled in `Stop`
- [ ] No personal data (serials, UDIDs, volume names, IP addresses)
