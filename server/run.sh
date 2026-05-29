#!/bin/bash
# Run the PostureMonitor MediaPipe + vision-LLM server.
#
# Port 8077 (NOT 8000) so it never collides with the StretchLab launchd server
# (com.stretchlab.server) which keeps :8000 for the StretchLab iOS app.
#
# Python: the deps (fastapi, mediapipe, anthropic) live in the stretch-lab .venv-mp.
# Override the interpreter with POSTURE_PY, the port with POSTURE_PORT.
cd "$(dirname "$0")"
PY="${POSTURE_PY:-/Users/randomblueberries/workspace/stretch-lab/.venv-mp/bin/python}"
PORT="${POSTURE_PORT:-8077}"
exec "$PY" -m uvicorn app:app --host 0.0.0.0 --port "$PORT"
