# Shipping PostureMonitor to the Mac App Store

You have the **paid Apple Developer Program** and Xcode is signed into your account, so distribution itself is included at no extra cost. **The app can be free to users** — a free price is fully compatible with notarization and the Store.

The blocker is **not** cost or paperwork. It's architecture.

---

## Your account specifics

- **Bundle id:** `com.shivam.posturemonitor` — matches your existing `com.shivam.*` convention. Not user-facing; no need to change.
- **Submit under your paid team** (the same one all your shipping apps already use) — pick it in Xcode → Signing & Capabilities. The exact Team ID is in local notes, kept out of this public repo.
- **Do NOT use the secondary Apple-ID dev cert** that happens to be in your keychain — it's not your publishing identity. `appstore/build.sh` auto-selects it only for *local* camera-permission signing.
- **No manual distribution cert needed:** Xcode auto-creates the "Apple Distribution" cert when you Archive under your team.

---

## ⛔ The one thing that must change first

The App Store requires every app to run in the **App Sandbox**. A sandboxed app **cannot spawn or talk to our local Python MediaPipe server** — no bundled Python runtime, no `127.0.0.1:8077`. So the Store version has to detect posture **natively, in-process**, with no server.

Two ways to do that:

| Option | What it is | Effort | Quality |
|---|---|---|---|
| **A — Vision-only** | Drop MediaPipe. Use Apple Vision's face position only (the absolute head-Y "whole-body-sinks" signal, ~88% in our tests). Lose the head-above-shoulders signal (needs shoulders) and the side forward-head signal. | ~half a day | One signal. A solid MVP, weaker than the full app. |
| **B — Core ML pose** | Bundle an on-device pose model (e.g. a MoveNet/BlazePose `.mlmodel`) so we get shoulders/ears natively, no Python. Reproduces most of the current detection. | ~2–4 days, plus model eval | Near-parity with today's app. The right long-term answer. |

> Apple's own `VNDetectHumanBodyPose` was tested and **fails at desk distance** — it is not a substitute. Core ML means a third-party pose model, not Apple's.

**Decision made: Option A (Vision-only).** The code below already exists.

---

## Already prepared in this repo

- **`appstore/` — a complete, self-contained Vision-only source set that compiles and runs.** No MediaPipe, no server, no network. `Engines.swift` (camera + Apple Vision face), `Config.swift` (settings in `UserDefaults`, since the sandbox blocks the home-dir JSON), `Views.swift`, `main.swift` (one-window app: preview, calibrate, sensitivity slider, nudges).
- `appstore/PostureMonitor.entitlements` — App Sandbox + camera. No network/process entitlements (a sandboxed app can't run the server).
- `appstore/Info.plist` — bundle id `com.shivam.posturemonitor`, version 1.0(1), min macOS 13, **`LSApplicationCategoryType` = Health & Fitness**, camera usage string.
- `appstore/build.sh` — builds + ad-hoc-signs a local `.app` **with the sandbox + camera entitlements** so you can smoke-test before Xcode. Run `./appstore/build.sh && open appstore/PostureMonitor.app`.

> What's intentionally gone vs the full app: the head-above-shoulders signal and the side forward-head camera (both need MediaPipe). Detection is the head-Y "whole-body-sinks" signal vs the calibrated baseline, scaled by the sensitivity slider.

## Steps to actually submit

1. ~~**App icon**~~ ✅ **Done** — `appstore/Assets.xcassets/AppIcon.appiconset` has the full macOS icon set (a seated-upright figure on the teal→green gradient). Regenerate any time with `swiftc appstore/iconGen.swift -o /tmp/g && /tmp/g`, then re-run `sips`. Swap in a designer icon later by replacing the PNGs.

2. **Create an Xcode project** (the source builds via raw `swiftc`; the Store needs a project to archive):
   - Xcode → File → New → Project → **macOS App** (AppKit, Swift). Bundle id `com.shivam.posturemonitor`.
   - Delete the template's `App`/`ContentView` files; **add the four `appstore/*.swift` files** and **`appstore/Assets.xcassets`** to the target. Set Build Settings → *Asset Catalog App Icon Set Name* = `AppIcon`.
   - Signing & Capabilities → pick your **team**, add **App Sandbox** + **Camera**, point at `appstore/PostureMonitor.entitlements` (or let Xcode manage them — the keys match).

3. **Archive & validate** — Xcode → Product → **Archive** → Organizer → **Validate App** (catches entitlement/signing issues before upload).

5. **App Store Connect** — create the app record (same bundle id), set **Price = Free**, fill metadata (name, subtitle, description, keywords, support URL), upload screenshots (1280×800 or 1440×900), and the **Privacy "Nutrition Label": Data Not Collected** — everything is on-device, nothing leaves the Mac. This is a genuine selling point.

6. **Upload** — Organizer → **Distribute App → App Store Connect**, then submit the build for review.

## Reality check

- The hard part — a self-contained, sandbox-safe app — is **done and compiling** (`appstore/`).
- What's left (icon, Xcode project, archive, App Store Connect metadata + review) is mechanical: roughly an afternoon plus Apple's review wait.
- The Vision-only Store app is intentionally lighter than the full app. The `git clone && ./start.sh` build stays the **full-power version** (MediaPipe + optional side camera) for anyone who doesn't mind running it from source.
