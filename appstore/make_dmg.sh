#!/bin/bash
# Build a distributable DMG of Don't Let Me Slouch.
#
#   ./make_dmg.sh [path/to/DontLetMeSlouch.app]
#
# For PUBLIC distribution, pass the Developer-ID-signed + notarized .app that
# Xcode exports via Organizer → Distribute App → Direct Distribution.
# With no argument it wraps the local dev build (fine for testing on your own
# Mac; other people's Macs will show Gatekeeper warnings for unsigned builds).
set -e
cd "$(dirname "$0")"

APP_SRC="${1:-PostureMonitor.app}"
[ -d "$APP_SRC" ] || { echo "✗ app not found: $APP_SRC  (build first: ./build.sh)"; exit 1; }

NAME="Dont Let Me Slouch"
VERSION=$(defaults read "$(cd "$APP_SRC" && pwd)/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.0")
DMG="DontLetMeSlouch-$VERSION.dmg"
STAGE=$(mktemp -d)

# Stage: the app (named properly) + an Applications symlink for drag-install.
cp -R "$APP_SRC" "$STAGE/Dont Let Me Slouch.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# If the app inside is notarized, staple the DMG too (harmless no-op otherwise).
xcrun stapler staple "$DMG" >/dev/null 2>&1 && echo "✓ stapled (notarized)" || echo "ℹ not stapled (app not notarized — fine for local testing)"

echo "done -> $(pwd)/$DMG  ($(du -h "$DMG" | cut -f1 | xargs))"
echo "test:  open $DMG"
