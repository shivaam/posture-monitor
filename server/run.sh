#!/bin/bash
# Run the MediaPipe posture server. Expects a venv at ../.venv with the
# requirements installed and pose_landmarker_heavy.task in this folder.
cd "$(dirname "$0")"
exec ../.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000
