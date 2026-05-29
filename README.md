# PostureMonitor

A native macOS posture monitor that watches you while you work and nudges you
when you slump or lean into the screen. **All local — your video never leaves
the Mac.**

It fuses two pose engines:

- **Apple Vision** (in the app, ~8 fps, no dependencies) — face position/size for
  fast, always-on tracking. Works with the server off.
- **MediaPipe** (a small local Python server) — real shoulder landmarks, which a
  laptop webcam's head-and-shoulders crop gives Apple Vision trouble with.

The app draws the live MediaPipe skeleton over your camera and shows a posture
score, status, and Head/Lean/Distance bars. A descending tone nudges you on a
sustained slump; a rising chime when you recover. Calibrate-free (it learns your
baseline) and pauses when you step away.

```
posture-monitor/
  app/      # native macOS app (Swift, AppKit + Vision) — built with build.sh
  server/   # MediaPipe pose server (FastAPI) the app talks to on localhost:8000
```

## Run it

**1. Server (for the MediaPipe shoulder tracking):**
```bash
cd server
python3 -m venv ../.venv
../.venv/bin/pip install -r requirements.txt
# one-time: download the pose model into server/
curl -L -o pose_landmarker_heavy.task \
  https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task
./run.sh
```

**2. App:**
```bash
cd app
./build.sh          # compiles + bundles + ad-hoc signs PostureMonitor.app
open PostureMonitor.app
```
Allow the camera prompt on first run. Sit how you want to hold posture; it
auto-calibrates after a few still seconds (or click **Calibrate**).

The app works **without the server** (Apple Vision only — head height + distance);
start the server to add the MediaPipe skeleton + shoulder-based detection.

## Notes / roadmap

- Front camera can't see front-to-back **rounded shoulders** (that's depth). A
  future **iPhone side-camera companion** (Continuity Camera) would add a side
  profile for true forward-head/rounding.
- To ship as a single binary, MediaPipe would need to run on-device (CocoaPods)
  instead of via the local server. Today it's app + local server.
- Logs to `/tmp/posture-monitor.log` for tuning thresholds.
