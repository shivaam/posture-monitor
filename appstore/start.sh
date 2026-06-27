#!/bin/bash
# Start the App Store (Vision-only) PostureMonitor.
set -e
cd "$(dirname "$0")"
./build.sh >/dev/null 2>&1 && echo "✓ built"
open PostureMonitor.app
echo "✓ launched — look for the menu-bar icon (top-right). Sit tall → Calibrate."
