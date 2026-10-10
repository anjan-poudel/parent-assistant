#!/bin/bash
set -euo pipefail
# Build + install + launch ElderlyAssistant on the connected iPhone over
# USB. No Xcode GUI needed — CLI package resolution doesn't suffer the
# GUI's stale-cache problems, and this uses its own DerivedData dir so it
# never fights an open Xcode session.
#
#   ./device-install.sh            build, install, launch
#   ./device-install.sh console    same, then stream the app's console

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
DERIVED="build/DerivedDataCli"

echo "=== Elderly Assistant — build + install to iPhone ==="

echo "[1/4] Regenerating project from project.yml..."
xcodegen generate >/dev/null

echo "[2/4] Finding connected iPhone..."
# Device state varies: "available (paired)" when fully paired,
# "connected" when freshly attached/locked — accept both. devicectl
# occasionally exits non-zero on daemon hiccups; || true keeps the
# pipefail shell from dying before the -z check can report.
DEVICE_ID="$( (xcrun devicectl list devices 2>/dev/null \
    | awk '/available \(paired\)|connected/ {print $3; exit}') || true )"
if [ -z "$DEVICE_ID" ]; then
    echo "ERROR: no iPhone found. Plug it in, unlock it, and tap Trust."
    exit 1
fi
UDID="$( (xcrun devicectl device info details --device "$DEVICE_ID" 2>/dev/null \
    | awk '/udid:/ {print $3; exit}') || true )"
if [ -z "$UDID" ]; then
    echo "ERROR: could not read the device UDID. Unlock the phone and retry."
    exit 1
fi
echo "      device: $UDID"

echo "[3/4] Building (first run takes a while — whisper.cpp)..."
xcodebuild -project seniOS.xcodeproj -scheme ElderlyAssistant \
    -destination "platform=iOS,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates build | tail -4

APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/ElderlyAssistant.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: build product not found at $APP_PATH"
    exit 1
fi

# The artifact is the source of truth for its own identity: launch exactly
# what was just installed. A hardcoded id went stale when the product was
# rebranded (`com.elderlyassistant.app` → `ai.voicebridge.senior.assistant`):
# the install used the built app and succeeded, the launch asked for the old
# id and died with CoreDeviceError 10002 "not installed" (Anzaan deploy,
# 2026-10-10 — the same failure a hardcoded NEW id would repeat at the next
# rename).
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist")"
if [ -z "$BUNDLE_ID" ]; then
    echo "ERROR: could not read CFBundleIdentifier from $APP_PATH/Info.plist"
    exit 1
fi
echo "      bundle id: $BUNDLE_ID"

echo "[4/4] Installing and launching..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
if [ "${1:-}" = "console" ]; then
    xcrun devicectl device process launch --console --device "$DEVICE_ID" "$BUNDLE_ID"
else
    if ! xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"; then
        echo "Launch failed — unlock the phone, then either tap the app icon"
        echo "or run: xcrun devicectl device process launch --device $DEVICE_ID $BUNDLE_ID"
        exit 1
    fi
    echo "Done. To stream the console next time: ./device-install.sh console"
fi
