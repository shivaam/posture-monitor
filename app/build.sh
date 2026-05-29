#!/bin/bash
# Build PostureMonitor.app — compile, assemble bundle, copy cues, ad-hoc sign.
set -e
cd "$(dirname "$0")"

APP="PostureMonitor.app"
echo "compiling…"
swiftc Engines.swift Views.swift Config.swift main.swift -O -o /tmp/PostureMonitor.bin

echo "assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp /tmp/PostureMonitor.bin "$APP/Contents/MacOS/PostureMonitor"
cp Info.plist "$APP/Contents/Info.plist"
cp cues/*.wav "$APP/Contents/Resources/" 2>/dev/null || echo "  (no cues found — run cue generation first)"

echo "signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "done -> $(pwd)/$APP"
echo "launch with:  open $APP"
