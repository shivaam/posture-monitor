#!/bin/bash
# PostureMonitor launcher — starts the MediaPipe/vision server (:8077) if needed,
# then opens the app. Safe to run repeatedly.
#
#   ~/workspace/posture-monitor/start.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

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
