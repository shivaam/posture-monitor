#!/bin/bash
# PostureMonitor pose server. On first run it creates a local venv, installs
# dependencies, and downloads the MediaPipe model — so anyone can just run this.
#
#   ./run.sh                 # starts on http://127.0.0.1:8077
#   POSTURE_PORT=9000 ./run.sh
#
# Needs Python 3.9–3.12 (MediaPipe doesn't support 3.13+ yet).
set -e
cd "$(dirname "$0")"

PORT="${POSTURE_PORT:-8077}"
VENV=".venv"
MODEL="pose_landmarker_heavy.task"
MODEL_URL="https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task"

# 1. venv + deps (first run only). MediaPipe needs Python 3.9–3.12, so pick a
# compatible interpreter (your default python3 may be too new). Override with POSTURE_PY.
if [ ! -x "$VENV/bin/python" ]; then
  PYBIN="$POSTURE_PY"
  if [ -z "$PYBIN" ]; then
    for c in python3.12 python3.11 python3.10 python3.9 python3; do
      command -v "$c" >/dev/null 2>&1 || continue
      minor=$("$c" -c 'import sys;print(sys.version_info[1])' 2>/dev/null || echo 99)
      if [ "$minor" -le 12 ] 2>/dev/null; then PYBIN="$c"; break; fi
    done
  fi
  [ -z "$PYBIN" ] && { echo "✗ need Python 3.9–3.12 for MediaPipe. Install one: brew install python@3.12"; exit 1; }
  echo "• first run: creating venv with $PYBIN + installing deps (~1–2 min)…"
  "$PYBIN" -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r requirements.txt
fi

# 2. model (first run only)
if [ ! -f "$MODEL" ]; then
  echo "• downloading MediaPipe pose model (~29 MB)…"
  curl -fsSL "$MODEL_URL" -o "$MODEL"
fi

echo "• pose server on http://127.0.0.1:$PORT"
exec "$VENV/bin/python" -m uvicorn app:app --host 127.0.0.1 --port "$PORT"
