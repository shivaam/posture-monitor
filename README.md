# PostureMonitor

A native macOS app that watches you through your laptop camera and **nudges you when you slouch**. No wearable, no cloud — everything runs on your Mac.

![PostureMonitor](docs/screenshot.png)

▶ **[10-second demo](docs/demo.mp4)**

---

## What it does

Sit up tall and click **Calibrate** — that's your baseline. Then it watches, and after you've held a slouch for a few seconds it nudges you with a sound and a red **"Sit up"** message. A quick glance down won't nag you (there's a grace period + smoothing).

It detects a slouch from up to three signals — head dropping toward your shoulders, your whole body sinking down, and (with an optional side camera) your head jutting forward. One clean status: **Good posture ✓** or a **Slouching — sit up in 5s…** countdown.

## Requirements

**Hardware**
- Any Mac running macOS (Apple Silicon or Intel).
- A camera — your **built-in webcam is all you need**.
- *Optional:* a second camera (a USB webcam, or your **iPhone via Continuity Camera**) placed to your side. It catches forward-head posture a front camera can't see. The app shows **Front view / Side view** pickers when a second camera is present.

**Software** (one-time setup, handled by `start.sh`)
- **Xcode command-line tools** — `xcode-select --install`
- **Python 3.9–3.12** — for the local pose server (MediaPipe doesn't support 3.13+ yet; `brew install python@3.12` if your default is newer).

## Quick start

```bash
git clone https://github.com/shivaam/posture-monitor
cd posture-monitor
./start.sh
```

First run builds the app, sets up the pose server (a local Python venv + model download), and launches everything — ~2 minutes. After that, `./start.sh` just opens it. You'll click **Allow** on the camera prompt once.

> Tip: add `alias posture='/full/path/to/posture-monitor/start.sh'` to your `~/.zshrc`, then just type `posture`.

## Privacy

**Everything runs locally and nothing is recorded.** Apple Vision runs inside the app; MediaPipe runs in a server on `127.0.0.1` (your machine only). No video or frames are saved to disk or sent anywhere, there are no accounts, and the only network request is a one-time model download during setup. Your camera feed never leaves your Mac.

## Tuning

Drag the in-app **sensitivity** slider (and re-calibrate), or create `~/.posturemonitor.json`:

```jsonc
{
  "slouchThresh": 0.90,    // sensitivity — lower = less sensitive (also scales the other signals)
  "slouchGrace": 8,        // seconds of slouch before it nudges
  "slouchCooldown": 45,    // min seconds between nudges
  "speakAlerts": false     // also say "sit up straight" out loud
}
```

## How it works

```
app/      native macOS app (Swift, AppKit + Apple Vision)
server/   local MediaPipe pose server (FastAPI) — /health + /posture
tools/    analysis + experiment scripts (not needed to run)
start.sh  one command to set up + launch everything
```

The app runs Apple Vision (face position) every frame and sends downscaled frames to the local server for MediaPipe pose landmarks (shoulders, ears), fusing them into the slouch signals above.

The path here wasn't obvious — we measured a lot and most of our intuitions were wrong. The full experiment log and data are in **[TECHNICAL.md](TECHNICAL.md)**.

## License

MIT — see [LICENSE](LICENSE).
