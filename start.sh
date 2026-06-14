#!/bin/bash
# PostureMonitor launcher — starts the MediaPipe/vision server (:8077) if needed,
# then opens the app. Safe to run repeatedly.
#
#   ~/workspace/posture-monitor/start.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

# 0. Pre-flight: the two prerequisites, checked up front with friendly guidance.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "✗ Xcode command-line tools missing. Install them, then re-run:"
  echo "    xcode-select --install"
  exit 1
fi
if [ ! -d "$HERE/app/PostureMonitor.app" ]; then
  ok=""
  for c in python3.12 python3.11 python3.10 python3.9 python3; do
    command -v "$c" >/dev/null 2>&1 || continue
    m=$("$c" -c 'import sys;print(sys.version_info[1])' 2>/dev/null || echo 99)
    [ "$m" -le 12 ] 2>/dev/null && ok="$c" && break
  done
  [ -z "$ok" ] && { echo "✗ Need Python 3.9–3.12 for MediaPipe (your python3 may be newer)."; echo "    brew install python@3.12"; exit 1; }
fi

# 1. Server on :8077 (only if not already responding)
if curl -s -m 2 http://127.0.0.1:8077/health >/dev/null 2>&1; then
  echo "✓ server already running on :8077"
else
  echo "• starting server on :8077 …"
  ( cd "$HERE/server" && nohup ./run.sh >| /tmp/posture-server.log 2>&1 & )
  for i in $(seq 1 40); do
    curl -s -m 2 http://127.0.0.1:8077/health >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -s -m 2 http://127.0.0.1:8077/health >/dev/null 2>&1 \
    && echo "✓ server up" || { echo "✗ server failed — see /tmp/posture-server.log"; tail -5 /tmp/posture-server.log; }
fi

# 2. The app — build on first run (or when --build is passed)
if [ ! -d "$HERE/app/PostureMonitor.app" ] || [ "$1" = "--build" ]; then
  echo "• building app (needs Xcode command-line tools: xcode-select --install) …"
  ( cd "$HERE/app" && ./build.sh >/dev/null 2>&1 ) && echo "✓ built" || { echo "✗ build failed — run app/build.sh to see why"; exit 1; }
fi
echo "• opening PostureMonitor …"
open "$HERE/app/PostureMonitor.app"
echo "✓ launched. Sit tall ~6s to calibrate, then it watches for slouching."
echo "  Logs: /tmp/posture-monitor.log   (server: /tmp/posture-server.log)"
