#!/bin/bash
# Capture the front PostureMonitor window → App Store screenshot (faces auto-blurred,
# framed on a 2560x1600 canvas). Usage: ./make_screenshots.sh "Caption" out.png
set -e
cd "$(dirname "$0")"
CAP="${1:-}"; OUT="${2:-/tmp/pm-store-shot.png}"
swiftc shotgen.swift -o /tmp/shotgen 2>/dev/null
cat > /tmp/getwin.swift <<'SWIFT'
import CoreGraphics; import Foundation
let o = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
let l = CGWindowListCopyWindowInfo(o, kCGNullWindowID) as? [[String:Any]] ?? []
for w in l where (w[kCGWindowOwnerName as String] as? String ?? "").contains("PostureMonitor") {
  print(w[kCGWindowNumber as String] as? Int ?? 0); break }
SWIFT
swiftc /tmp/getwin.swift -o /tmp/getwin 2>/dev/null
WID=$(/tmp/getwin)
[ -z "$WID" ] && { echo "PostureMonitor window not found — is it open?"; exit 1; }
screencapture -o -x -l"$WID" /tmp/pm-raw.png
/tmp/shotgen /tmp/pm-raw.png "$OUT" "$CAP"
