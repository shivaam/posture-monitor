#!/bin/bash
# Local build of the Vision-only App Store variant — for smoke-testing BEFORE you
# wrap it in an Xcode project. This is NOT the Store build (that's Xcode Archive);
# it just proves the source set runs, sandboxed, with the App Store entitlements.
set -e
cd "$(dirname "$0")"

APP="PostureMonitor.app"
echo "compiling (Vision-only)…"
swiftc Engines.swift Views.swift Config.swift Prefs.swift main.swift -O -o /tmp/PostureMonitorAS.bin

echo "assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp /tmp/PostureMonitorAS.bin "$APP/Contents/MacOS/PostureMonitor"
cp Info.plist "$APP/Contents/Info.plist"

# Sign with the sandbox + camera entitlements (ad-hoc is fine for a local run;
# the Store build re-signs with your Developer ID via Xcode).
codesign --force --deep --options runtime \
  --entitlements PostureMonitor.entitlements --sign - "$APP"

echo "done -> $(pwd)/$APP"
echo "test it:  open $APP"
