#!/bin/bash
# Build PostureMonitor.app — compile, assemble bundle, ad-hoc sign.
# Needs Xcode command-line tools (xcode-select --install).
set -e
cd "$(dirname "$0")"

APP="PostureMonitor.app"
echo "compiling…"
swiftc Engines.swift Views.swift Config.swift SideCamera.swift main.swift -O -o /tmp/PostureMonitor.bin

echo "assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp /tmp/PostureMonitor.bin "$APP/Contents/MacOS/PostureMonitor"
cp Info.plist "$APP/Contents/Info.plist"

# Sign with a STABLE identity if one exists, so macOS keeps the camera permission
# across rebuilds (ad-hoc signatures change every build and re-trigger the prompt).
# Override with POSTURE_SIGN_ID; falls back to ad-hoc for users without a cert.
SIGN_ID="${POSTURE_SIGN_ID:-}"
[ -z "$SIGN_ID" ] && SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)".*/\1/')
if [ -n "$SIGN_ID" ]; then
  echo "signing with: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  echo "signing (ad-hoc — camera prompt may reappear on rebuilds)…"
  codesign --force --deep --sign - "$APP"
fi

echo "done -> $(pwd)/$APP"
echo "launch with:  open $APP"
