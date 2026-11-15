# drobo-driverkit

A macOS driver for the **Drobo 8D** Thunderbolt array on **Apple silicon** Macs.

Drobo, Inc. is gone. Their Thunderbolt driver is a kernel extension that modern Macs only load
if you lower the machine's security settings, and it will stop working entirely as Apple removes
kext support. This project replaces it with a DriverKit driver extension: no kext, no Reduced
Security, System Integrity Protection stays on.

Other open projects cover Drobo's network (NAS) models. As far as we know this is the only one
for the direct-attached Thunderbolt units.

## Status

| | |
|---|---|
| Drobo 8D over Thunderbolt 3 | Works |
| Reading your volumes | **Works** (HFS+ volumes mount read-only) |
| Writing | **Experimental and off by default.** You enable it per volume in the app. Implemented but not yet verified on hardware: keep a copy of anything on a volume you make writable |
| APFS volumes on the Drobo | macOS will not mount APFS from a write-protected disk; they need "Allow writes" |
| Health, capacity, drive bays, rebuild progress | **Works**, shown in the included app |
| Per-drive temperature, error count, firmware and serial | Experimental and off by default (Advanced → Read drive details). Not yet tried on hardware. The Drobo does not expose full S.M.A.R.T. data |
| Rename the Drobo, safe shutdown, per-volume mount/unmount | In the app; rename and shutdown not yet verified on hardware |
| Blink lights | **Turned off.** As sent today it makes the 8D stop responding and restart |
| Dual disk redundancy and spin-down settings, cache flush on eject, sleep/wake | Implemented, not yet verified on hardware |
| Creating/deleting Drobo volumes, firmware updates, reset | Not supported. Erasing or reformatting an existing volume works from Disk Utility once writing is on |
| Other Thunderbolt Drobos (5D, 5D3, Mini) | **Untested, probably fine.** The driver now attaches to them; see [Other models](#other-models) |
| USB Drobos | No driver needed: macOS mounts them itself. The app and `drobo` do not show them yet |
| Intel Macs | Not supported; use Drobo's original driver there |
| Menu bar item, background monitoring, notifications, open at login | In the app (Settings) |
| Update checks (release or nightly channel) | Tells you when a newer version exists; installing it still means rebuilding |
| A ready-to-run download | **Not available yet**, see below |

In short: today this is a way to **get your data off** a Drobo 8D using a current Mac, and to
see what state the unit is in while you do.

## Command line

The app includes `drobo`, a read-only status command for shell prompts, tmux or vim status
lines, scripts and dashboards. It reads what the driver publishes and never sends anything to
the Drobo.

Install it from the app: **Install Command Line Tool…** in the app menu, the menu bar item or
Settings. That links `/usr/local/bin/drobo` to the copy inside the app and asks for an
administrator password if the folder needs one.

```bash
drobo                       # Drobo: healthy · 7.4 TB of 34.4 TB used (22%) · 9/9 drives
drobo --short               # Drobo ok 22%
drobo all                   # device, every bay, every volume
drobo drive 3               # one bay
drobo volume "Time Machine" # one volume, by name or unit number
drobo get percent           # one bare value; `drobo keys` lists them
drobo all --json            # for dashboards
drobo --watch 5             # redraw every 5 seconds
drobo diagnostics > d.json  # raw driver state for a bug report, serial and name removed
```

The exit status is 0 when healthy, 1 for a warning or a rebuild, 2 when the Drobo needs
attention and 3 when it is not connected, so `drobo >/dev/null || notify` works in scripts.
`--demo healthy` or `--demo rebuilding` prints made-up data without a Drobo.

## Alerts and diagnostics

With notifications on (Settings), the app tells you when a status warning appears or clears, a
drive changes state, the driver reports I/O errors, or the Drobo disconnects, stops responding or
comes back. Settings also takes an optional webhook address: each alert is then posted there as a
small JSON message (`title`, `body`, `level`, `time`, plus `text` and `content` for chat
services), so it reaches you when nobody is at the Mac.

**Save Diagnostics…** (app menu, or the Advanced tab) writes what the driver publishes, including
the raw status pages, to a JSON file. The Drobo's serial number and name are overwritten; drive
model strings are kept; volume names are not included. Nothing is sent to the Drobo or uploaded.
Attach that file to bug reports.

## Why there is no download yet

Apple controls which developers may ship hardware drivers. Anyone with a paid developer account
can build and run a driver like this one on **their own** Macs. Shipping one build that works on
**everyone's** Mac needs Apple to grant extra "distribution" entitlements for this specific
hardware. That request is pending. Until it is granted, a notarized download cannot exist, no
matter who builds it.

So for now you build and sign it yourself. It takes about 30 minutes and you do it once a year.

## What you need

- An Apple silicon Mac (M1 or later) running macOS 14 or later.
- A Drobo 8D and a real **Thunderbolt 3** cable (lightning-bolt logo). A plain USB-C cable looks
  the same and will not work.
- A paid **Apple Developer Program** membership (US $99/year). A free Apple ID is not enough;
  Apple does not allow driver capabilities on free accounts.
- [Xcode](https://apps.apple.com/app/xcode/id497799835) (free, from the Mac App Store).
- [Homebrew](https://brew.sh) to install one small tool.

## Install, step by step

You do not need to know how to program. You will copy a few commands into Terminal and click
through Apple's developer website.

### 1. Get the tools

Install Xcode from the App Store and open it once so it finishes setting up. Then, in Terminal:

```bash
brew install xcodegen
```

```bash
git clone https://github.com/JoeMatt/drobo-driverkit.git
```

```bash
cd drobo-driverkit
```

### 2. Pick your own app identifier

Apple needs every app to have a unique ID, so you cannot reuse ours. Choose a prefix that is
yours, for example `com.yourname`. Also find your **Team ID**: sign in at
[developer.apple.com/account](https://developer.apple.com/account), open **Membership details**,
and copy the 10-character Team ID.

Open `project.yml` in any text editor and change three lines:

| Line | Change to |
|---|---|
| `DEVELOPMENT_TEAM: S32Z3HMYVQ` | your Team ID |
| `PRODUCT_BUNDLE_IDENTIFIER: com.joemattiello.DroboDriverKit` | `com.yourname.DroboDriverKit` |
| `PRODUCT_BUNDLE_IDENTIFIER: com.joemattiello.DroboDriverKit.driver` | `com.yourname.DroboDriverKit.driver` |

The second ID must be the first one plus `.driver`.

### 3. Register your Mac and the two identifiers with Apple

On [developer.apple.com/account](https://developer.apple.com/account), open
**Certificates, Identifiers & Profiles**.

1. **Devices** → **+** → platform macOS. Enter any name and your Mac's Provisioning UDID. To find
   it: Apple menu → About This Mac → More Info → System Report → Hardware → *Provisioning UDID*.
2. **Identifiers** → **+** → App IDs → App. Bundle ID: Explicit, `com.yourname.DroboDriverKit`.
   Tick **System Extension**. Save.
3. **Identifiers** → **+** again. Bundle ID `com.yourname.DroboDriverKit.driver`. Tick:
   - **DriverKit**
   - **DriverKit PCI (development)**
   - **DriverKit Family SCSI Controller (development)**
   - **DriverKit Allow Any UserClient Access** (lets the app's buttons talk to the driver)

   Save.

If you cannot find **DriverKit PCI (development)** in the list, your account does not have it
and you will need to ask Apple Developer Support to enable it. Without it the build will not
sign.

### 4. Build

Open Xcode → Settings → Accounts and make sure your Apple ID is signed in. Then, in Terminal,
from the `drobo-driverkit` folder:

```bash
xcodegen generate
```

```bash
xcodebuild -project DroboDriverKit.xcodeproj -scheme DroboHost -configuration Release -derivedDataPath build -allowProvisioningUpdates build
```

It should end with `** BUILD SUCCEEDED **`. If it complains about a provisioning profile or an
entitlement, re-check step 3: the capability names must match exactly.

### 5. Install

The app must live in your Applications folder or macOS will refuse to load the driver.

```bash
cp -R build/Build/Products/Release/DroboDriverKit.app /Applications/
```

1. Open **DroboDriverKit** from Applications and click **Activate**.
2. macOS says a system extension was blocked. Open **System Settings → General → Login Items &
   Extensions → Driver Extensions** and switch **DroboDriverKit** on.
3. Back in the app it should say **Done.**

That approval is the normal consent prompt for any driver. It does not lower your Mac's
security.

### 6. Connect the Drobo

Power the Drobo on, wait for it to finish starting (a few minutes, until the lights settle),
then plug in the Thunderbolt cable. Its volumes appear in Finder within a few seconds.

If macOS ever says *"The disk you attached was not readable by this computer"*, click
**Ignore**. **Never click Initialize**, and do not run First Aid on these disks.

## Updating, and the yearly renewal

Apple's development signing lasts one year. When it expires the driver stops loading; repeat
steps 4 and 5 to renew. Do the same to install a newer version of this project:
`git pull`, rebuild, copy to Applications, eject the Drobo's volumes, click **Activate** again.

## Troubleshooting

| Symptom | What to do |
|---|---|
| The Drobo does not appear under System Information → Thunderbolt | It is the cable, the port, or the Drobo is still starting up. No driver can help until it shows there. |
| Activate says "will complete after a restart" | Restart the Mac with the Drobo plugged in. |
| Activate fails with an entitlement or signature error | The identifiers in step 3 do not match `project.yml`, or a capability is missing. |
| The Driver Extensions switch turned itself off | Turn it back on, then unplug and replug the Drobo. |
| An APFS volume on the Drobo will not mount | Expected while the driver is read-only. |

To see what the driver is doing:

```bash
ioreg -r -c IOUserSCSIParallelInterfaceController -l -w0 | grep DroboStatus
```

## Removing it

Open DroboDriverKit and click **Deactivate**, then delete the app from Applications.

## Other models

**Other Thunderbolt Drobos (5D, 5D3, Mini): not tested, probably fine.** Drobo's own driver
handled two PCI IDs with the same code: `4452:3844` (the 8D, tested here) and `4452:5570`, which
is probably the 5D-family Thunderbolt units. Since v0.24.0 this driver attaches to both. Nobody
has tried the second one yet. It starts read-only like the 8D, and it refuses to run if the
unit does not describe its interface the way the 8D does, in which case the app's Advanced tab
shows the stage it stopped at. If you have one, please open an issue with what happens and
attach a diagnostics file. Expect rough edges in the app, which labels bays the way the 8D
numbers them.

**USB Drobos** do not need this driver: macOS mounts them as ordinary USB disks. What is missing
is the dashboard, because the status pages are read with commands that macOS does not let an app
send to a mounted USB disk on its own. Whether that can be done without a second driver is an
open question in the backlog.

## For developers

Contributing, including with AI coding agents: start with [AGENTS.md](AGENTS.md). Feature
coverage against the original Drobo software is tracked in [docs/03-coverage.md](docs/03-coverage.md).

- [Protocol notes](docs/01-protocol-reverse-engineering.md): BAR layout, the `DroboPort`
  shared-memory structure, the self-describing doorbell tables, request and response formats,
  measurements from real hardware, and the SCSIControllerDriverKit pitfalls hit along the way.
- [Feasibility and entitlements](docs/02-feasibility-and-entitlements.md): the signing paths
  and what each needs from Apple.

Layout:

- `DroboHost/`: SwiftUI app whose only job is to activate the driver extension.
- `DroboDriver/`: the dext, an `IOUserSCSIParallelInterfaceController` on `IOPCIDevice`.
  `DroboProtocol.h` holds the wire structures.
- `project.yml`: [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the `.xcodeproj` is
  generated from it.
- `.github/workflows/build.yml`: compile check on every push.
- `.github/workflows/release.yml`: Developer ID + notarization pipeline. Dormant and unrun until
  Apple grants the distribution entitlements.

Compile without signing:

```bash
xcodebuild -project DroboDriverKit.xcodeproj -scheme DroboHost -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Roadmap: verifying on hardware everything marked unverified above.

The management pages the app shows are read with the protocol documented by the open-source
[drobo-utils](https://github.com/petersilva/drobo-utils) project.

## Disclaimer

This is an independent interoperability project, not affiliated with or endorsed by Drobo, Inc.
or its successors. It contains no Drobo code. It talks to hardware that holds your data: keep a
backup, and use it at your own risk. Licensed under the [MIT License](LICENSE).
