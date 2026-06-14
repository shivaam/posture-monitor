# PostureMonitor — Technical Findings

A running record of what we tried, assumed, measured, and concluded while building
a desk-posture monitor. Bias toward **evidence over intuition** — most of our
strong intuitions turned out wrong, and the data corrected them.

---

## 0. Goal (as it evolved)

- Started broad: a multi-dimensional "posture score" (slump + lean + distance + rounded shoulders).
- Collapsed to the real job: **alert the user when they slouch.** One job, simple heuristic, ~80% of cases. Everything below is in service of that.

## 1. Setup / stack

- **App:** native macOS (AppKit, `swiftc` build, ad-hoc codesigned). Live camera + MediaPipe skeleton overlay + score/bars.
- **3 cameras:** FaceTime HD (front, 0°), Logitech BRIO (USB webcam, positionable ~45°), iPhone via Continuity Camera ("Shiv Camera", ~90° side). All enumerated by the app; the app holds the camera TCC grants.
- **Engines:** Apple Vision (face bbox → head height, face size) + **MediaPipe** pose (shoulders, ears, nose; head-above-shoulders, shoulder tilt) via a local **FastAPI server on :8077** (`pose_engine.posture`).
- **Vision LLM:** local Anthropic proxy at `localhost:42069`, `claude-sonnet-4`, used for setup-diagnosis + (evaluated) posture judging.
- **Frame quality:** raised from 320px/0.5 JPEG → **720px/0.8** for sharper MediaPipe + LLM analysis.
- **Ground-truth labeling:** a guided **🎯 Test** mode — on-screen prompts ("sit tall", "slouch", "forward head, eyes up", "look down, back straight") → each HOLD-second captures every candidate metric + frames from all 3 cameras, labeled by the prompt. This is *true* ground truth (the prompt is the label), and it beat every other labeling approach.

## 2. Signals we tried

| Signal | Source | Verdict |
|---|---|---|
| `mpHeadAbove` = (shoulderMidY − noseY)/shoulderWidth | MediaPipe front | **Winner.** Shoulder-relative (chair-height invariant) |
| `visHeadY` (face bbox midY) | Apple Vision front | Works (88%) but absolute (breaks if chair/camera moves) |
| `noseToShoulderY`, `earToShoulderY` | MediaPipe front | Work (~88%), variants of "head dropped" |
| `visFaceSize` (distance/lean-in) | Apple Vision front | Weak (79%) |
| `mpTilt` (shoulder tilt = "lean") | MediaPipe front | **Useless (62%).** See §4 |
| `mpShoulderWidth` | MediaPipe front | Useless (62%); only useful as a *rotation* guard |
| **Side forward-head** (ear ahead of shoulder) | MediaPipe side | **The forward-head signal.** Robust to looking down |
| Vision LLM (baseline-compare) | local proxy | **Too inaccurate (65–69%).** See §5 |
| Apple Vision **3D** body pose | `VNDetectHumanBodyPose3DRequest` | **Unusable at desk distance.** See §6 |

## 3. Assumptions — and which broke

| Assumption | Reality |
|---|---|
| Front camera can't see forward-head | **Partly false** — front `mpHeadAbove` dropped Δ−2.69 for forward-head; jutting the head forward lowers it enough |
| Need a 90° side camera (phone) | **False** — a **45° webcam catches forward-head** (Δ+2.38) |
| The vision LLM would be a good judge | **False** — 65–69%, misses most slouches |
| Shoulder-tilt "lean" is a real signal | **False** — statistical noise (sep 0.51) |
| More signals fused = better score | **False** — one signal (88%) beat the 4-signal `min()` composite |
| Multi-camera needs the app updated per camera | Generalized to N side cameras (continuity-first); ffmpeg/standalone can't grab cameras (TCC) — only the granted app can |

## 4. Data — what separates upright from slouch

**Guided labeled test (28 samples: 12 good / 12 slouch / 4 normal), ranked by separation (|Δmean|/pooled-σ) and threshold accuracy:**

| metric | separation | accuracy | good → slouch |
|---|---|---|---|
| **mpHeadAbove** | **2.92** | **88%** | 1.24 → 0.93 (slouch lower) |
| noseToShoulderY | 2.47 | 88% | 0.295 → 0.223 |
| visHeadY | 2.47 | 88% | 0.672 → 0.555 |
| noseY | 2.39 | 88% | (slouch higher) |
| earToShoulderY | 2.26 | 88% | 0.307 → 0.243 |
| shoulderMidY | 2.08 | 88% | |
| visFaceSize | 1.61 | 79% | |
| **mpTilt (lean)** | **0.51** | **62%** | 10.7° → 12.1° — **noise** |
| mpShoulderWidth | 0.14 | 62% | — noise |

> **Most surprising result of the project:** the "lean" signal we'd bolted *three* patches onto (rotation guard + deadzone + LLM-mute) is statistically useless for posture (0.51). We were engineering around a non-signal.

## 5. Data — how accurate is the vision LLM? (baseline-compare, 23 held-out frames)

| LLM config | accuracy | slouch recall | false-alarm on upright |
|---|---|---|---|
| Front only | **65%** | **33%** (4/12) | 0% |
| Front + side (BRIO) | **69%** | 66% | 27% |

- Front-only the LLM is *cautious to a fault* — it says "posture maintained" and **misses ⅔ of slouches**.
- Adding the side view **doubles recall** (33→66%) — confirming slouch is more visible from the side — but it starts **false-alarming (27%)**. Ceiling ~70%.
- **Conclusion:** the LLM is **not** accurate enough to be the detector (heuristic 88% ≫ LLM 69%). It *is* genuinely good at **camera-placement coaching** ("move the side camera back to see the full ear" was correct). **Demote it to setup help + optional once-a-minute second opinion**, never the real-time alert. (Latency, by the way, is a non-issue — slouch is sustained, a 60s check is fine. Accuracy is the disqualifier.)

## 6. Data — side camera forward-head, and the 45° experiment

**First side analysis (head-down slouch test):** forward-head angle (ear ahead of shoulder):

| side camera | upright | slouch | separation |
|---|---|---|---|
| BRIO (oblique) | 14.7° | 18.4° | 1.83 |
| iPhone (clean profile) | 5.2° | 14.0° | **2.35** |

**The 45° experiment** (16 good / 8 forward-head-eyes-up / 4 look-down-straight-back / 4 slouch), forward-head Δ vs upright:

| posture | front `headAbove` Δ | **BRIO @ 45° fwdHead Δ** | iPhone @ 90° fwdHead Δ |
|---|---|---|---|
| **forward-head (eyes up)** | −2.69 | **+2.38** ✅ | +1.91 ✅ |
| look-down (back straight) | −2.15 | +1.45 | +1.69 |
| slouch | −2.70 | +1.72 | +1.77 |

- **45° works** — the BRIO at 45° caught forward-head (Δ+2.38), edging the iPhone at 90° (+1.91). **No phone required.**
- **The front caught forward-head too** (headAbove Δ−2.69) — so the *theoretical* "front is blind to forward-head-looking-up" didn't fully hold in practice.
- **Residual confound:** "looking down with a straight back" looks similar to bad posture on *both* front and side (no clean geometric separator). **Handled temporally** — the 8s grace period filters brief look-downs, since users don't *hold* a head-down-straight-back pose.
- Absolute angles differ by camera (BRIO baseline 15.9°, iPhone 6.5°) → everything is **baseline-relative** (calibrate, then alert on deviation), so absolute angle doesn't matter.

## 7. Apple Vision 3D body pose — dead end at desk distance

- `VNDetectHumanBodyPose3DRequest` on real desk frames: **`results: 0` (no body) or hard SIGSEGV (exit 139)**. Trained for full-body shots; a head-and-shoulders desk crop is out of distribution. Matches the earlier 2D `VNDetectHumanBodyPoseRequest` failure (`bodyObs=false`). So **no native single-camera depth shortcut** — MediaPipe (or a side angle) is required for ear+shoulder.

## 8. Infra / distribution findings

- **MediaPipe can't ship in a sandboxed Mac App Store app** (iOS-oriented CocoaPods; SitApp confirms it's why they're off the MAS). **Apple-Vision-only apps ship fine** (Posturr proves it). → Path: Vision-native core on the App Store; **MediaPipe fusion as a notarized-DMG power tier**.
- **Camera access:** only the granted app can read cameras. `ffmpeg`/standalone binaries are **TCC-denied** from the shell; `screencapture` works (screen-recording granted). Camera TCC **resets on some ad-hoc re-signs** — recurring dev friction (fix: a stable self-signed identity, not yet done).
- **Port conflict:** a launchd agent (`com.stretchlab.server`, KeepAlive) owns **:8000** for the StretchLab iOS backend → PostureMonitor moved to **:8077** (`POSTURE_SERVER` env overrides).
- **Server runtime:** runs from `~/workspace/stretch-lab/.venv-mp` (Python 3.12 with fastapi+mediapipe+anthropic) — *not* the `../.venv` that `run.sh` referenced.
- **Market (research):** crowded but thin — a swarm of solo-dev front-camera apps (SitApp, Slouch Sniper, Straighty, SuperShrimp, SitWit, Posturr) + a funded incumbent (Zen, YC S21, $3.5M). Their shared unsolved gap: **front cameras can't see forward-head/rounded shoulders** — our wedge. Pricing: avoid $9.99/mo; ~$4.99/mo or $29–39/yr + lifetime option.

## 9. Final architecture (data-driven, de-patched)

```
calibrate (sit tall) → capture baseHeadAbove (front) + baseSideDeg (side)
slouch = (mpHeadAbove < 0.87 × baseHeadAbove)         # head drops  (front)
      OR (sideForwardHead > baseSideDeg + 6°)          # head forward (side, 45° ok)
held ≥ 8s grace, ≥45s cooldown → nudge
```

- **One "Posture" bar** = worse of the two signals. **MediaPipe skeleton overlay kept** (liked).
- **Alerts:** big auto-dismiss on-screen toast (red slouch / green recover) + clear system sound (Funk/Glass) + optional spoken nudge (`speakAlerts`).
- **LLM:** out of the detection loop; kept for camera-placement help.
- **Tunables** in `~/.posturemonitor.json`: `slouchThresh` 0.87, `sideSlouchMargin` 6°, `slouchGrace` 8s, `slouchCooldown` 45s.

## 10. Tooling we built (reusable)

- `🎯 Test` mode — prompted ground-truth capture (all cameras + metrics).
- `labeled_analyze.py` — ranks metrics by good/slouch separation, picks threshold.
- `fhp_analyze.py` — per-camera forward-head vs head-above per posture (the 45° experiment).
- `llm_eval.py` — measures LLM slouch accuracy vs ground truth.
- `selfloop.py` — LLM-labeled self-tuning loop (now secondary, since guided labels beat LLM labels).

## 11. Open / next

- Prove forward-head-looking-up more rigorously (small n: 8 forward-head, 4 look-down).
- Stable signing identity to stop camera-TCC resets each rebuild.
- Decide front-only (simplest, ~88%) vs front-OR-side (more robust) as the shipped default.
- App-Store-safe packaging decision (Vision-only core vs DMG).
