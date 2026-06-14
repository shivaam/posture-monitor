#!/bin/bash
# Build PostureMonitor.app — compile, assemble bundle, ad-hoc sign.
# Needs Xcode command-line tools (xcode-select --install).
set -e
cd "$(dirname "$0")"

APP="PostureMonitor.app"
echo "compiling…"
swiftc Engines.swift Views.swift Config.swift main.swift -O -o /tmp/PostureMonitor.bin

echo "assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp /tmp/PostureMonitor.bin "$APP/Contents/MacOS/PostureMonitor"
cp Info.plist "$APP/Contents/Info.plist"

echo "signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "done -> $(pwd)/$APP"
echo "launch with:  open $APP"
