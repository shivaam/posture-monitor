# App Store listing — PostureMonitor

Fill these into **App Store Connect** when you submit. App is **Free**, category **Health & Fitness**.

## Name & subtitle
- **App Name** (≤30): `PostureMonitor`
- **Subtitle** (≤30): `Gentle posture nudges`

## Promotional text (≤170)
> A calm menu-bar coach that watches your posture on-device and nudges you when you slump. No account, no cloud — your camera never leaves your Mac.

## Keywords (≤100, comma-separated)
```
posture,slouch,ergonomics,neck,back,sitting,desk,health,wellness,reminder,wfh,spine,rsi,break
```

## Description
```
PostureMonitor is a calm, private posture coach that lives in your Mac’s menu bar.
Sit up straight, calibrate once, and it gently nudges you whenever you start to
slump — so you build a better habit without thinking about it.

Everything happens on your Mac. Your camera feed is never recorded, never
uploaded, and never leaves the device. No account, no subscription, no cloud.

FEATURES
• One-tap calibration — set your upright baseline in seconds.
• Gentle nudges — a sound, a soft screen-edge glow, and/or an on-screen banner.
  Pick any combination.
• Two modes — Continuous (always watching) or Periodic (a quick check every few
  minutes).
• Smart timing — only nudges on a sustained slump, with a grace period so a quick
  glance down won’t nag you, and a chime when you straighten back up.
• Adjustable sensitivity and nudge delay.
• Compact window — shrink it to a small status pill and park it in a corner.
• Menu-bar status at a glance — green when you’re good, red when you’re slouching.
• 100% on-device. 100% private. Free.

Sit taller, feel better. PostureMonitor quietly has your back.
```

## What’s New (version 1.0)
```
First release. Calibrate, then get gentle on-device nudges when you slump —
sound, screen-edge glow, or banner. Continuous or periodic checking, adjustable
sensitivity, and a compact corner mode. Everything stays on your Mac.
```

## Privacy “nutrition label”
- **Data collection: NONE.** Select **“Data Not Collected.”**
- All processing is on-device (Apple Vision). No analytics, no network calls, no accounts.
- Privacy Policy URL is **required** by Apple — host `PRIVACY.md` (see below) somewhere public (e.g. GitHub Pages or the repo) and link it.

## Required URLs (you must provide)
- **Support URL** (required): a page where users can get help. Simplest: the GitHub repo, or a one-page site. *(You said skip in-app contact — that’s fine, but the Store still needs a URL here.)*
- **Privacy Policy URL** (required): link to the hosted `PRIVACY.md`.

## Review notes (paste into "Notes for Reviewer")
```
PostureMonitor uses the Mac’s camera purely for on-device posture detection
(Apple Vision). No video or images are recorded, stored, or transmitted; there
is no network activity and no account. To test: grant camera access, sit upright
and click Calibrate, then slump — a nudge fires after the grace period. The app
keeps a small window visible while monitoring (macOS pauses the camera for
hidden windows); a "Compact window" mode shrinks it to a status pill.
```

## Screenshots
- Required size (macOS): **2560×1600** or **1280×800** (16:10). 1–10 images.
- Plan: see `make_screenshots.sh` — captures the app and blurs the face, framed with captions. Suggested set:
  1. Good posture (main window) — “Sit up straight, gently.”
  2. Slouching nudge — “A calm nudge when you slump.”
  3. Preferences — “Your nudges, your way.”
  4. Compact pill — “Tuck it in a corner.”
