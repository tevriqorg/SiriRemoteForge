#!/bin/bash

# Creates a proper macOS app bundle structure

set -e

APP_NAME="HyperVibe"
APP_BUNDLE="${HYPERVIBE_APP_BUNDLE_PATH:-.build/HyperVibe-Dev.app}"
BINARY_PATH="${HYPERVIBE_BINARY_PATH:-$APP_NAME}"
APP_VERSION="${HYPERVIBE_VERSION:-1.0.0}"
BUILD_NUMBER="${HYPERVIBE_BUILD_NUMBER:-1}"
RELEASE_VERSION="${HYPERVIBE_RELEASE_VERSION:-${APP_VERSION}-local.${BUILD_NUMBER}}"
APP_BUNDLE_ID="${HYPERVIBE_BUNDLE_ID:-org.tevriq.siriremoteforge}"
BROKER_BUNDLE_ID="${APP_BUNDLE_ID}.CredentialBroker"
UPDATE_FEED_URL="${HYPERVIBE_UPDATE_FEED_URL:-}"
UPDATE_PUBLIC_KEY="${HYPERVIBE_UPDATE_PUBLIC_KEY:-}"
SIGN_MODE="${HYPERVIBE_SIGN_MODE:-developer}"
SPARKLE_ROOT="$(./prepare_sparkle.sh)"

IS_LOCAL_BUILD=false
case "$RELEASE_VERSION" in
    *-local.*) IS_LOCAL_BUILD=true ;;
esac

if { [ -n "$UPDATE_FEED_URL" ] && [ -z "$UPDATE_PUBLIC_KEY" ]; } \
   || { [ -z "$UPDATE_FEED_URL" ] && [ -n "$UPDATE_PUBLIC_KEY" ]; }; then
    echo "Error: HYPERVIBE_UPDATE_FEED_URL and HYPERVIBE_UPDATE_PUBLIC_KEY must be supplied together."
    exit 1
fi
if [ "$IS_LOCAL_BUILD" = false ] && { [ -z "$UPDATE_FEED_URL" ] || [ -z "$UPDATE_PUBLIC_KEY" ]; }; then
    echo "Error: non-local builds require an explicit fork-owned Sparkle feed URL and public key."
    exit 1
fi

if ! [[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "Error: HYPERVIBE_VERSION must be numeric (for example 0.1.0), got: $APP_VERSION"
    exit 1
fi
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: HYPERVIBE_BUILD_NUMBER must be an integer, got: $BUILD_NUMBER"
    exit 1
fi
if ! [[ "$RELEASE_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.-]*$ ]]; then
    echo "Error: invalid HYPERVIBE_RELEASE_VERSION: $RELEASE_VERSION"
    exit 1
fi
if ! [[ "$APP_BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
    echo "Error: invalid HYPERVIBE_BUNDLE_ID: $APP_BUNDLE_ID"
    exit 1
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: $BINARY_PATH executable not found."
    echo "Please build first with: ./build.sh"
    exit 1
fi
if [ ! -f "HyperVibeCredentialBroker" ]; then
    echo "Error: HyperVibeCredentialBroker executable not found."
    echo "Please build first with: ./build.sh"
    exit 1
fi

case "$APP_BUNDLE" in
    *.app) ;;
    *)
        echo "Error: HYPERVIBE_APP_BUNDLE_PATH must name a .app bundle: $APP_BUNDLE"
        exit 1
        ;;
esac

if [ "$SIGN_MODE" = "developer" ]; then
    case "$APP_BUNDLE" in
        /Applications|/Applications/*)
            echo "Error: developer packaging must stage outside /Applications."
            echo "Build/sign/verify first; installation is a separate rollback-protected step."
            exit 1
            ;;
    esac
fi

echo "Creating clean app bundle: $APP_BUNDLE"
mkdir -p "$(dirname "$APP_BUNDLE")"
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
mkdir -p "${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc/Contents/MacOS"

# Copy executable
cp "$BINARY_PATH" "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"
cp "HyperVibeCredentialBroker" \
    "${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc/Contents/MacOS/HyperVibeCredentialBroker"
/usr/bin/ditto "$SPARKLE_ROOT/Sparkle.framework" \
    "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
/bin/cp "$SPARKLE_ROOT/LICENSE" "${APP_BUNDLE}/Contents/Resources/Sparkle-LICENSE.txt"

# Generate the app icon if it's missing (it's a build artifact — .icns is git-ignored).
if [ ! -f "HyperVibe.icns" ] && [ -f "tools/make_app_icon.swift" ]; then
    echo "Generating app icon..."
    TMP_ICONSET="$(mktemp -d)/HyperVibe.iconset"
    if swift tools/make_app_icon.swift "$TMP_ICONSET" >/dev/null 2>&1 \
        && iconutil -c icns "$TMP_ICONSET" -o "HyperVibe.icns" 2>/dev/null; then
        echo "App icon generated"
    else
        echo "Icon generation skipped (swift/iconutil unavailable)"
    fi
fi

# Copy icon if it exists
if [ -f "HyperVibe.icns" ]; then
    cp "HyperVibe.icns" "${APP_BUNDLE}/Contents/Resources/HyperVibe.icns"
    echo "Icon added to app bundle"
elif [ -f "SiriRemote.icns" ]; then
    cp "SiriRemote.icns" "${APP_BUNDLE}/Contents/Resources/HyperVibe.icns"
    echo "Icon added to app bundle"
fi

# Copy every authored app resource, including nested Voice sounds and their license. `ditto`
# preserves the directory structure and merges with generated icons/licenses already copied above.
if [ -d "Resources" ]; then
    /usr/bin/ditto "Resources" "${APP_BUNDLE}/Contents/Resources"
    for voice_asset in VoiceToggleOn.mp3 VoiceToggleOff.mp3 UI-SFX-LICENSE.txt; do
        if [ ! -f "${APP_BUNDLE}/Contents/Resources/Sounds/${voice_asset}" ]; then
            echo "Error: required Voice feedback resource is missing: ${voice_asset}"
            exit 1
        fi
    done
    echo "App resources added to app bundle"
fi

# Create proper Info.plist with all required keys
echo "Creating Info.plist..."
cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$APP_BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>CFBundleShortVersionString</key>
	<string>$APP_VERSION</string>
	<key>HyperVibeReleaseVersion</key>
	<string>$RELEASE_VERSION</string>
	<key>CFBundleIconFile</key>
	<string>HyperVibe</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 HyperVibe Contributors</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<!-- Login Items and a manual reopen must converge on the same running process. Without this,
	     LaunchServices may create a second LSUIElement instance, duplicating HID/media handling. -->
	<key>LSMultipleInstancesProhibited</key>
	<true/>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>HyperVibe needs Bluetooth access to connect to your Siri Remote trackpad.</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>HyperVibe needs Bluetooth access to connect to your Siri Remote trackpad.</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>siriRemote sends AppleScript to apps you bind (e.g. play/pause Apple Music) when the remote's buttons are pressed.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>HyperVibe uses your selected microphone for push-to-talk dictation, transcription, and its live waveform.</string>
	<!-- Sparkle update policy. Runtime choices are mirrored from config.jsonc; these values provide
	     secure first-launch defaults before that config has been migrated by the GUI. -->
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUAllowsAutomaticUpdates</key>
	<true/>
	<key>SUAutomaticallyUpdate</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
	<key>SUVerifyUpdateBeforeExtraction</key>
	<true/>
</dict>
</plist>
EOF

if [ -n "$UPDATE_FEED_URL" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $UPDATE_FEED_URL" \
        "${APP_BUNDLE}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $UPDATE_PUBLIC_KEY" \
        "${APP_BUNDLE}/Contents/Info.plist"
fi
if [ "$IS_LOCAL_BUILD" = true ]; then
    /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" \
        "${APP_BUNDLE}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :SUAllowsAutomaticUpdates false" \
        "${APP_BUNDLE}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :SUAutomaticallyUpdate false" \
        "${APP_BUNDLE}/Contents/Info.plist"
fi

# Keep this embedded service byte-for-byte and metadata-stable across UI releases. The login
# keychain grants its CDHash access once, while the broker mutually authenticates the containing
# App by code-signing requirement before accepting any XPC message.
cat > "${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>HyperVibeCredentialBroker</string>
	<key>CFBundleIdentifier</key>
	<string>$BROKER_BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>HyperVibeCredentialBroker</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>XPCService</key>
	<dict>
		<key>ServiceType</key>
		<string>Application</string>
	</dict>
</dict>
</plist>
EOF

APP_PLIST="${APP_BUNDLE}/Contents/Info.plist"
BROKER_PLIST="${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc/Contents/Info.plist"
/usr/bin/plutil -lint "$APP_PLIST" "$BROKER_PLIST" >/dev/null

[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP_PLIST")" = "$APP_BUNDLE_ID" ] || {
    echo "Error: generated App bundle identifier does not match $APP_BUNDLE_ID"
    exit 1
}
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$BROKER_PLIST")" = "$BROKER_BUNDLE_ID" ] || {
    echo "Error: generated Credential Broker identifier does not match $BROKER_BUNDLE_ID"
    exit 1
}

if [ "$IS_LOCAL_BUILD" = true ]; then
    for forbidden in SUFeedURL SUPublicEDKey; do
        if /usr/bin/plutil -extract "$forbidden" raw -o - "$APP_PLIST" >/dev/null 2>&1; then
            echo "Error: local development bundle unexpectedly contains $forbidden"
            exit 1
        fi
    done
    for key in SUEnableAutomaticChecks SUAllowsAutomaticUpdates SUAutomaticallyUpdate; do
        [ "$(/usr/bin/plutil -extract "$key" raw -o - "$APP_PLIST")" = "false" ] || {
            echo "Error: local development bundle must set $key=false"
            exit 1
        }
    done
else
    [ "$(/usr/bin/plutil -extract SUFeedURL raw -o - "$APP_PLIST")" = "$UPDATE_FEED_URL" ] || {
        echo "Error: generated release feed URL does not match HYPERVIBE_UPDATE_FEED_URL"
        exit 1
    }
    [ "$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$APP_PLIST")" = "$UPDATE_PUBLIC_KEY" ] || {
        echo "Error: generated release public key does not match HYPERVIBE_UPDATE_PUBLIC_KEY"
        exit 1
    }
fi

# Keep the license with every binary distribution, including the app-only Release asset.
if [ -f "../LICENSE" ]; then
    cp "../LICENSE" "${APP_BUNDLE}/Contents/Resources/LICENSE.txt"
fi
if [ -f "../NOTICE" ]; then
    cp "../NOTICE" "${APP_BUNDLE}/Contents/Resources/NOTICE.txt"
fi

# Make executable
chmod +x "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"
chmod +x "${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc/Contents/MacOS/HyperVibeCredentialBroker"

# Sign WITHOUT hardened runtime on the outer app. The app loads the private MultitouchSupport framework and
# takes its touch callback; under the hardened runtime that callback trips code-signing enforcement
# and the process is SIGKILLed with "Code Signature Invalid" the instant you touch the trackpad.
# (The raw dev binary works precisely because it has no hardened runtime.) Entitlements are embedded
# but only matter under hardened runtime, so they're harmless here.
[ -f "HyperVibe.entitlements" ] || { echo "Error: HyperVibe.entitlements not found"; exit 1; }

# Development builds belong to this fork and must use the developer's own Apple Development
# identity. Never fall back silently to ad-hoc signing: changing the designated requirement changes
# TCC/Keychain identity and would make permission failures look like App regressions.
#
# Selection order:
#   1. exact HYPERVIBE_SIGN_ID supplied by the developer;
#   2. exactly one valid "Apple Development:" identity in the default keychain search list.
#
# If several Apple Development identities exist, selection is intentionally explicit.
SIGN_ID="${HYPERVIBE_SIGN_ID:-}"
CODESIGN_KEYCHAIN_ARGS=()

if [ "$SIGN_MODE" = "developer" ]; then
    if [ -z "$SIGN_ID" ]; then
        DEV_IDENTITIES=()
        while IFS= read -r identity; do
            [ -n "$identity" ] && DEV_IDENTITIES+=("$identity")
        done < <(
            security find-identity -v -p codesigning 2>/dev/null \
                | sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-Fa-f]* "\(Apple Development:.*\)"$/\1/p'
        )
        if [ "${#DEV_IDENTITIES[@]}" -eq 0 ]; then
            echo "Error: no valid Apple Development signing identity was found."
            echo "Install/select your Apple Development certificate, or set HYPERVIBE_SIGN_ID explicitly."
            exit 1
        fi
        if [ "${#DEV_IDENTITIES[@]}" -ne 1 ]; then
            echo "Error: multiple Apple Development signing identities are available:"
            printf '  %s\n' "${DEV_IDENTITIES[@]}"
            echo "Set HYPERVIBE_SIGN_ID to the exact identity you want to use."
            exit 1
        fi
        SIGN_ID="${DEV_IDENTITIES[0]}"
    fi

    if ! security find-identity -v -p codesigning 2>/dev/null \
        | grep -Fq "\"$SIGN_ID\""; then
        echo "Error: requested signing identity is not currently valid: $SIGN_ID"
        exit 1
    fi
    echo "Signing development build with: $SIGN_ID"
elif [ "$SIGN_MODE" = "adhoc" ]; then
    SIGN_ID="-"
    echo "Ad-hoc signing (explicit public/release artifact only)..."
else
    echo "Error: HYPERVIBE_SIGN_MODE must be 'developer' or 'adhoc', got: $SIGN_MODE"
    exit 1
fi

# Sparkle's helpers retain hardened runtime even though HyperVibe itself cannot use it. Sign from
# the deepest nested code outward; --deep is verification-only and is never used to construct a
# signature because it can hide a malformed framework bundle.
SPARKLE_B="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B"
CREDENTIAL_XPC="${APP_BUNDLE}/Contents/XPCServices/HyperVibeCredentialBroker.xpc"
codesign --force --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "$CREDENTIAL_XPC"
codesign --force --options runtime --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "$SPARKLE_B/XPCServices/Installer.xpc"
codesign --force --options runtime --preserve-metadata=entitlements \
    --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "$SPARKLE_B/XPCServices/Downloader.xpc"
codesign --force --options runtime --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "$SPARKLE_B/Autoupdate"
codesign --force --options runtime --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "$SPARKLE_B/Updater.app"
codesign --force --options runtime --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"

if ! codesign --force --entitlements "HyperVibe.entitlements" \
    --sign "$SIGN_ID" "${CODESIGN_KEYCHAIN_ARGS[@]}" "${APP_BUNDLE}"; then
    echo "Error: app signing failed. The existing installed App was not touched."
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
codesign -dvv "${APP_BUNDLE}" 2>&1 | grep -E "(Authority|flags|Identifier)" || true

echo ""
echo "✓ App bundle created: $APP_BUNDLE"
echo ""
echo "Development candidate is staged and signed."
echo "Do NOT launch it while the installed stable HyperVibe is running."
echo "Verify first:"
echo "  codesign --verify --deep --strict --verbose=2 \"$APP_BUNDLE\""
echo ""
echo "A real-device test is a separate promotion step: back up the installed stable App,"
echo "stop it, install this candidate at /Applications/HyperVibe.app, then grant/re-check"
echo "Accessibility, Input Monitoring and Microphone permissions for the new code identity."
