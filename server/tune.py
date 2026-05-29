"""tune.py — close the self-improving loop.

Claude vision is the TEACHER (independent ground-truth labels per frame); the
cheap MediaPipe + thresholds are the STUDENT. We grid-search the app's three
thresholds (sensitivity / tilt / proximity) to best match Claude's verdicts on
recorded clips, then print the tuned defaults.

    ../.venv/bin/python tune.py <clip1.mp4> [clip2.mp4 ...]   # real clips (need sidecars)
    ../.venv/bin/python tune.py --selftest                    # validate the optimizer offline

Each clip needs its .events.jsonl sidecar (app metrics + calibration baseline).
"""
import json
import os
import sys

SENS = [0.78, 0.80, 0.82, 0.85, 0.88, 0.90]
TILT = [5, 7, 9, 11, 14]
MARGIN = [0.10, 0.14, 0.18, 0.22]


def classify(headRatio, tiltDev, widthRatio, sens, tilt, margin):
    """Mirror the app's logic -> 'good' or a fault, given candidate thresholds."""
    if widthRatio > 1 + margin:
        return "too_close"
    if headRatio < sens:
        return "slumping"
    if tiltDev > tilt:
        return "leaning"
    return "good"


def grid_search(dataset):
    """dataset: list of (headRatio, tiltDev, widthRatio, claudeLabel). Returns best
    thresholds by good-vs-bad agreement with Claude."""
    best = None
    for s in SENS:
        for t in TILT:
            for m in MARGIN:
                agree = 0
                for hr, td, wr, label in dataset:
                    pred = classify(hr, td, wr, s, t, m)
                    if (pred == "good") == (label == "good"):
                        agree += 1
                acc = agree / max(1, len(dataset))
                if best is None or acc > best[0]:
                    best = (acc, s, t, m)
    return best


def dataset_from_clip(path):
    """Build (features, claude label) per sampled frame from a recorded clip."""
    import cv2
    import vision_label as VL
    import anthropic

    sp = path.rsplit(".", 1)[0] + ".events.jsonl"
    if not os.path.exists(sp):
        print("  no sidecar for", path, "- skipping"); return []
    samples, cal = [], None
    for ln in open(sp):
        try:
            e = json.loads(ln)
        except Exception:
            continue
        if e.get("type") == "sample":
            samples.append(e)
        elif e.get("type") == "calibrate":
            cal = e
    if not cal or not samples:
        print("  clip missing calibration/samples - skipping"); return []
    baseHead = cal.get("baseHead") or 1
    baseTilt = cal.get("baseTilt") or 0
    baseWidth = cal.get("baseWidth") or 1

    client = anthropic.Anthropic(api_key="local-test", base_url="http://localhost:42069/v1")
    model = "claude-sonnet-4-20250514"
    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    rows, i = [], 0
    sample_times = {round(s["t"], 1): s for s in samples}
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        t = round(i / fps, 1)
        if t in sample_times:
            s = sample_times[t]
            _, buf = cv2.imencode(".jpg", frame)
            v = VL.label(client, model, buf.tobytes())
            hr = (s.get("headY", baseHead)) / baseHead
            td = abs((s.get("tilt", baseTilt)) - baseTilt)
            wr = (s.get("faceSize", baseWidth)) / baseWidth
            rows.append((hr, td, wr, v.get("posture", "?")))
        i += 1
    cap.release()
    return rows


def selftest():
    # Fabricate a labeled set: good / slump / lean / too-close clusters + noise.
    import random
    random.seed(7)
    data = []
    for _ in range(25):
        data.append((random.uniform(0.95, 1.05), random.uniform(0, 3), random.uniform(0.95, 1.05), "good"))
    for _ in range(15):
        data.append((random.uniform(0.70, 0.83), random.uniform(0, 4), random.uniform(0.95, 1.1), "slumping"))
    for _ in range(15):
        data.append((random.uniform(0.95, 1.05), random.uniform(11, 18), random.uniform(0.95, 1.05), "leaning"))
    for _ in range(15):
        data.append((random.uniform(0.95, 1.1), random.uniform(0, 4), random.uniform(1.22, 1.4), "too_close"))
    best = grid_search(data)
    print("self-test on %d synthetic frames" % len(data))
    print("recovered thresholds: sensitivity=%.2f tilt=%d° proximity=%.2f  (agreement %.0f%%)"
          % (best[1], best[2], best[3], best[0] * 100))


def main():
    if len(sys.argv) < 2 or sys.argv[1] == "--selftest":
        selftest(); return
    data = []
    for clip in sys.argv[1:]:
        print("labeling", os.path.basename(clip), "with Claude vision…")
        data += dataset_from_clip(clip)
    if not data:
        print("no labeled frames — record clips with the app (they include sidecars) first."); return
    best = grid_search(data)
    print("\n%d labeled frames across %d clip(s)" % (len(data), len(sys.argv) - 1))
    print("BEST thresholds vs Claude: sensitivity=%.2f tilt=%d° proximity=%.2f  (agreement %.0f%%)"
          % (best[1], best[2], best[3], best[0] * 100))
    print("Put these in PostureLogic (sensitivity / tiltThresh / proximityMargin).")


if __name__ == "__main__":
    main()
