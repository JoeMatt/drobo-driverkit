#!/bin/bash
# Download or update DroboDriverKit, build it signed with YOUR Apple Developer team, and
# install it to /Applications.
#
# This exists because there is no notarized download yet: Apple has not granted the
# distribution entitlements, so every owner has to sign their own build (README, "Why there is
# no download yet"). It automates README steps 1, 2, 4 and 5. Step 3, registering your Mac and
# two identifiers on Apple's developer site, cannot be scripted; the script tells you exactly
# what to enter there and waits.
#
#   scripts/install.sh                 from a checkout
#   curl -fsSL https://raw.githubusercontent.com/JoeMatt/drobo-driverkit/master/scripts/install.sh | bash
#
# Run it again to update to the newest version, or to renew the yearly development signing.
# It never lowers a security setting, never talks to the Drobo, and uses sudo only if your
# account cannot write to /Applications.

set -euo pipefail

REPO_URL="https://github.com/JoeMatt/drobo-driverkit.git"
PRODUCT="DroboDriverKit"
HELPER="DroboHelper"
CLI="drobo"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/drobo-driverkit"
CONFIG="$CONFIG_DIR/install.env"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install.sh [options]

  --team ID        Your 10-character Apple Developer Team ID
  --prefix PREFIX  Your bundle identifier prefix, e.g. com.yourname
  --source DIR     Where the source lives or should be cloned (default: the checkout this
                   script is in, otherwise ~/drobo-driverkit)
  --ref REF        Branch, tag or commit to build (default: master)
  --no-update      Build the source as it is; do not fetch or switch versions
  --build-only     Build and verify, but do not copy to /Applications
  --check          Only check that this Mac has what the build needs
  --yes            Do not pause for confirmation (values must come from flags or a previous run)
  -h, --help       Show this help

Your Team ID and prefix are remembered in ~/.config/drobo-driverkit/install.env.
EOF
}

# Reads one remembered value. The file is parsed, never executed.
remembered() {
    [ -f "$CONFIG" ] || return 0
    sed -n "s|^$1=\\([A-Za-z0-9./-]*\\)\$|\\1|p" "$CONFIG" | head -n 1
}

remember() {
    mkdir -p "$CONFIG_DIR"
    printf 'TEAM=%s\nPREFIX=%s\nPORTAL=%s\n' "$TEAM" "$PREFIX" "$PORTAL" > "$CONFIG"
}

# Prompts on the terminal even when the script itself arrives on stdin (curl | bash).
ask() {
    local prompt="$1" default="${2:-}" answer=""
    [ "$ASSUME_YES" = 1 ] && { printf '%s' "$default"; return 0; }
    [ -r /dev/tty ] || die "No terminal to ask on. Pass --team and --prefix (and --yes)."
    if [ -n "$default" ]; then prompt="$prompt [$default]"; fi
    printf '%s: ' "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty || true
    printf '%s' "${answer:-$default}"
}

pause() {
    [ "$ASSUME_YES" = 1 ] && return 0
    [ -r /dev/tty ] || return 0
    printf '%s' "$1" > /dev/tty
    IFS= read -r _ < /dev/tty || true
}

valid_team()   { printf '%s' "$1" | grep -Eq '^[A-Z0-9]{10}$'; }
valid_prefix() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'; }

preflight() {
    step "Checking this Mac"
    local problems=0
    problem() { say "  ✗ $*"; problems=$((problems + 1)); }
    ok()      { say "  ✓ $*"; }

    if [ "$(uname -s)" != Darwin ]; then die "This only runs on macOS."; fi
    if [ "$(uname -m)" = arm64 ]; then ok "Apple silicon"
    else problem "This Mac is not Apple silicon. The driver is arm64 only."; fi

    local os major
    os="$(sw_vers -productVersion)"
    major="${os%%.*}"
    if [ "$major" -ge 14 ] 2>/dev/null; then ok "macOS $os"
    else problem "macOS $os is too old; 14 or later is needed."; fi

    if xcodebuild -version >/dev/null 2>&1; then ok "$(xcodebuild -version | head -n 1)"
    else problem "Xcode is missing or not set up. Install it from the App Store, open it once, then run: sudo xcode-select -s /Applications/Xcode.app"; fi

    if xcodebuild -showsdks 2>/dev/null | grep -qi driverkit; then ok "DriverKit SDK"
    else problem "Xcode has no DriverKit SDK. Update Xcode."; fi

    if command -v git >/dev/null 2>&1; then ok "git"; else problem "git is missing (it comes with Xcode)."; fi

    if command -v xcodegen >/dev/null 2>&1; then ok "xcodegen"
    elif [ "$CHECK_ONLY" = 1 ]; then problem "xcodegen is missing. Install it with: brew install xcodegen"
    elif command -v brew >/dev/null 2>&1; then
        say "  … installing xcodegen with Homebrew"
        brew install xcodegen >/dev/null || problem "brew install xcodegen failed."
        command -v xcodegen >/dev/null 2>&1 && ok "xcodegen"
    else problem "xcodegen is missing. Install Homebrew (https://brew.sh), then: brew install xcodegen"; fi

    [ "$problems" -eq 0 ] || die "$problems thing(s) above need fixing first."
}

# The checkout this script is running from, if it is one.
own_checkout() {
    local script="${BASH_SOURCE[0]:-}"
    [ -n "$script" ] && [ -f "$script" ] || return 0
    local dir
    dir="$(cd "$(dirname "$script")/.." 2>/dev/null && pwd)" || return 0
    [ -f "$dir/project.yml" ] && [ -d "$dir/DroboDriver" ] && printf '%s' "$dir"
    return 0
}

fetch_source() {
    step "Getting the source"
    if [ ! -e "$SOURCE" ]; then
        [ "$UPDATE" = 1 ] || die "$SOURCE does not exist and --no-update was given."
        git clone --quiet "$REPO_URL" "$SOURCE"
        say "  Cloned into $SOURCE"
    fi
    [ -f "$SOURCE/project.yml" ] || die "$SOURCE is not a drobo-driverkit checkout."

    if [ "$UPDATE" = 1 ]; then
        git -C "$SOURCE" rev-parse --git-dir >/dev/null 2>&1 || die "$SOURCE is not a git checkout; pass --no-update to build it as it is."
        if [ -n "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ]; then
            die "$SOURCE has local changes. Your Team ID and prefix no longer need to be edited into project.yml; undo that with 'git -C \"$SOURCE\" checkout project.yml', or pass --no-update to build what is there."
        fi
        git -C "$SOURCE" fetch --quiet --tags origin
        if git -C "$SOURCE" show-ref --verify --quiet "refs/remotes/origin/$REF"; then
            git -C "$SOURCE" checkout --quiet "$REF" 2>/dev/null || git -C "$SOURCE" checkout --quiet -b "$REF" "origin/$REF"
            git -C "$SOURCE" merge --quiet --ff-only "origin/$REF" || die "Could not fast-forward $REF in $SOURCE."
        else
            git -C "$SOURCE" checkout --quiet --detach "$REF" || die "No branch, tag or commit named $REF."
        fi
    fi
    say "  Building $(git -C "$SOURCE" describe --tags --always 2>/dev/null || echo 'the source as it is') in $SOURCE"
}

# Team ID of an Apple Development certificate already in the keychain, as a suggestion.
guess_team() {
    security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^ *organizationalUnitName *= *\([A-Z0-9]\{10\}\)$/\1/p' | head -n 1 || true
}

configure() {
    step "Your Apple Developer details"
    TEAM="${TEAM:-$(remembered TEAM)}"
    PREFIX="${PREFIX:-$(remembered PREFIX)}"
    PORTAL="$(remembered PORTAL)"

    if ! valid_team "$TEAM"; then
        say "  Your Team ID is on https://developer.apple.com/account under Membership details."
        TEAM="$(ask '  Team ID (10 characters)' "$(guess_team)")"
    fi
    valid_team "$TEAM" || die "'$TEAM' is not a Team ID: expected 10 letters and digits."

    if ! valid_prefix "$PREFIX"; then
        say "  Apple needs your own app identifier. Pick a prefix that is yours, e.g. com.yourname."
        PREFIX="$(ask '  Identifier prefix')"
    fi
    valid_prefix "$PREFIX" || die "'$PREFIX' is not a usable prefix: expected something like com.yourname."
    if [ "$PREFIX" = com.joemattiello ] && [ "$TEAM" != S32Z3HMYVQ ]; then
        die "com.joemattiello belongs to the project's maintainer; choose your own prefix."
    fi

    APP_ID="$PREFIX.$PRODUCT"
    say "  Team $TEAM, app identifier $APP_ID"

    if [ "$PORTAL" != "$TEAM/$APP_ID" ]; then
        local udid
        udid="$(system_profiler SPHardwareDataType 2>/dev/null | sed -n 's/^ *Provisioning UDID: *//p')"
        cat <<EOF

  One thing only you can do, once, at https://developer.apple.com/account
  under Certificates, Identifiers & Profiles (a paid developer membership is required):

    1. Devices → + → macOS. Any name, and this Mac's Provisioning UDID:
         ${udid:-(System Information → Hardware → Provisioning UDID)}
    2. Identifiers → + → App IDs → App. Explicit bundle ID:
         $APP_ID
       Tick: System Extension
    3. Identifiers → + again. Explicit bundle ID:
         $APP_ID.driver
       Tick: DriverKit
             DriverKit PCI (development)
             DriverKit Family SCSI Controller (development)
             DriverKit Allow Any UserClient Access

  Also sign in to your Apple ID in Xcode → Settings → Accounts.
  If "DriverKit PCI (development)" is not offered, Apple Developer Support has to enable it.

EOF
        pause "  Press Return when that is done (Ctrl-C to stop here)… "
        PORTAL="$TEAM/$APP_ID"
    fi
    remember
}

build() {
    step "Building and signing (this takes a few minutes)"
    local log="$SOURCE/build/install-build.log"
    mkdir -p "$SOURCE/build"
    (cd "$SOURCE" && xcodegen generate --quiet)
    # Team and identifiers go in as overrides, so project.yml stays untouched and updatable.
    if ! xcodebuild -project "$SOURCE/$PRODUCT.xcodeproj" -scheme DroboHost -configuration Release \
            -derivedDataPath "$SOURCE/build" -allowProvisioningUpdates \
            DEVELOPMENT_TEAM="$TEAM" DROBO_APP_ID="$APP_ID" build > "$log" 2>&1; then
        grep -E 'error:|Provisioning|entitlement' "$log" | sort -u | head -n 20 >&2 || true
        die "The build failed. Signing errors nearly always mean an identifier or capability in the developer portal does not match the list above. Full log: $log"
    fi
    BUILT="$SOURCE/build/Build/Products/Release/$PRODUCT.app"
    [ -d "$BUILT" ] || die "The build finished but $BUILT is missing."
    say "  Built $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist")"
}

signed_field() { codesign -d --verbose=4 "$1" 2>&1 | sed -n "s/^$2=//p" | head -n 1; }

# Everything that executes must carry your team's signature: macOS will not load the driver
# otherwise, and the privileged helper refuses to serve an app from any other team.
verify() {
    step "Checking the signatures"
    local dext="$BUILT/Contents/Library/SystemExtensions/$APP_ID.driver.dext"
    local helper="$BUILT/Contents/MacOS/$HELPER"
    local plist="$BUILT/Contents/Library/LaunchDaemons/$APP_ID.helper.plist"
    [ -d "$dext" ] || die "The driver extension is missing from the built app."
    [ -f "$helper" ] || die "The privileged helper is missing from the built app."
    [ -f "$plist" ] || die "The privileged helper's launchd plist is missing from the built app."

    codesign --verify --deep --strict "$BUILT" || die "The built app's signature does not verify."
    local item team
    for item in "$BUILT" "$dext" "$helper" "$BUILT/Contents/MacOS/$CLI"; do
        team="$(signed_field "$item" TeamIdentifier)"
        [ "$team" = "$TEAM" ] || die "$(basename "$item") is signed by '${team:-nobody}', not team $TEAM."
        say "  ✓ $(basename "$item")"
    done
    [ "$(signed_field "$helper" Identifier)" = "$APP_ID.helper" ] || die "The privileged helper has the wrong signing identifier."
    [ "$(lipo -archs "$dext/$APP_ID.driver" 2>/dev/null)" = arm64 ] || die "The driver must be arm64 only."
}

install_app() {
    step "Installing to /Applications"
    local dest="/Applications/$PRODUCT.app"
    local staged="/Applications/.$PRODUCT.installing.app"
    local previous="/Applications/.$PRODUCT.previous.app"
    local sudo=""
    if [ ! -w /Applications ]; then
        say "  Your account cannot write to /Applications; an administrator password is needed."
        sudo="sudo"
    fi

    if pgrep -x "$PRODUCT" >/dev/null 2>&1; then
        say "  Quitting the running app"
        osascript -e "tell application id \"$APP_ID\" to quit" >/dev/null 2>&1 || true
        local waited=0
        while pgrep -x "$PRODUCT" >/dev/null 2>&1 && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
        pgrep -x "$PRODUCT" >/dev/null 2>&1 && die "$PRODUCT is still running. Quit it (menu bar item → Quit) and run this again."
    fi

    # Copy next to the destination first, so a failed copy never leaves a half-installed app.
    $sudo rm -rf "$staged" "$previous"
    $sudo ditto "$BUILT" "$staged"
    if [ -e "$dest" ]; then $sudo mv "$dest" "$previous"; fi
    $sudo mv "$staged" "$dest"
    $sudo rm -rf "$previous"
    say "  Installed $dest"

    cat <<EOF

Done. What is left is in the app and System Settings:

  1. Eject the Drobo's volumes if any are mounted.
  2. Open $PRODUCT and click Activate.
  3. First time only: System Settings → General → Login Items & Extensions →
     Driver Extensions → switch $PRODUCT on.
  4. Unplug and replug the Drobo if its volumes do not appear.

Standard (non-admin) accounts: the first Mount, Unmount or Eject asks an administrator to
allow $PRODUCT under Login Items & Extensions → Allow in the Background, once.

Development signing lasts a year. Run this script again to renew it or to update.
EOF
    if [ "$ASSUME_YES" != 1 ]; then open "$dest" || true; fi
}

main() {
    TEAM="" PREFIX="" SOURCE="" REF="master" UPDATE=1 BUILD_ONLY=0 CHECK_ONLY=0 ASSUME_YES=0
    APP_ID="" PORTAL="" BUILT=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --team)       [ $# -ge 2 ] || die "--team needs a value"; TEAM="$2"; shift 2 ;;
            --prefix)     [ $# -ge 2 ] || die "--prefix needs a value"; PREFIX="$2"; shift 2 ;;
            --source)     [ $# -ge 2 ] || die "--source needs a value"; SOURCE="$2"; shift 2 ;;
            --ref)        [ $# -ge 2 ] || die "--ref needs a value"; REF="$2"; shift 2 ;;
            --no-update)  UPDATE=0; shift ;;
            --build-only) BUILD_ONLY=1; shift ;;
            --check)      CHECK_ONLY=1; shift ;;
            --yes)        ASSUME_YES=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            usage >&2; die "Unknown option: $1" ;;
        esac
    done

    preflight
    if [ "$CHECK_ONLY" = 1 ]; then say; say "This Mac can build $PRODUCT."; exit 0; fi

    if [ -z "$SOURCE" ]; then SOURCE="$(own_checkout)"; fi
    SOURCE="${SOURCE:-$HOME/drobo-driverkit}"

    fetch_source
    configure
    build
    verify
    if [ "$BUILD_ONLY" = 1 ]; then say; say "Built and verified: $BUILT"; exit 0; fi
    install_app
}

# Everything is inside functions and started from the last line, so the whole file is read
# before anything runs: a partial download does nothing, and updating the checkout this script
# lives in cannot change it mid-run.
main "$@"
