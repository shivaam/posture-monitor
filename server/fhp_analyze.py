"""fhp_analyze.py — does a 45° (or any) camera catch FORWARD-HEAD?

Runs MediaPipe on the guided-Test frames and, per camera angle (front 0°, side0,
side1), reports the forward-head angle (ear ahead of shoulder) and head-above
per labeled posture, plus separation vs 'good'. The money question:

  - side cameras: good vs forward_head -> does fwdHead jump? (45° catches FHP?)
  - front:        good vs forward_head -> headAbove should NOT move (front is blind)
  - any:          good vs look_down    -> fwdHead should stay flat (robust to pitch)

    python fhp_analyze.py
"""
import glob
import math
import os
import statistics as st

import pose_engine

LAB = os.path.expanduser("~/Movies/PostureMonitor/labeled")
LABELS = ["good", "forward_head", "look_down", "slouch", "normal"]


def label_of(p):
    b = os.path.basename(p)
    for L in LABELS:
        if f"_{L}_" in b:
            return L
    return "?"


def metrics(path):
    r = pose_engine.posture(open(path, "rb").read())
    lms = r.get("landmarks", {})

    def g(k):
        v = lms.get(k)
        return v if v and len(v) >= 3 and v[2] > 0.3 else None

    best = None
    for e, s in [("leftEar", "leftShoulder"), ("rightEar", "rightShoulder")]:
        ev, sv = g(e), g(s)
        if ev and sv:
            vis = min(ev[2], sv[2])
            dx = abs(ev[0] - sv[0]); dy = max(1e-4, abs(sv[1] - ev[1]))
            deg = math.degrees(math.atan2(dx, dy))
            if best is None or vis > best[0]:
                best = (vis, deg)
    return (best[1] if best else None), r.get("head_above")


def sep(a, b):
    if len(a) < 2 or len(b) < 2:
        return None
    pooled = (st.pstdev(a) + st.pstdev(b)) / 2 or 1e-9
    return (st.mean(b) - st.mean(a)) / pooled


def summarize(cam, name):
    files = glob.glob(os.path.join(LAB, f"{cam}_*.jpg"))
    if not files:
        return
    print(f"\n=== {cam} ({name}) ===")
    byl = {L: {"fh": [], "ha": []} for L in LABELS}
    for p in files:
        L = label_of(p)
        if L not in byl:
            continue
        fh, ha = metrics(p)
        if fh is not None:
            byl[L]["fh"].append(fh)
        if ha is not None:
            byl[L]["ha"].append(ha)
    for L in LABELS:
        fh, ha = byl[L]["fh"], byl[L]["ha"]
        if fh or ha:
            print(f"  {L:<13} "
                  f"{('fwdHead=%5.1f° (n%d)' % (st.mean(fh), len(fh))) if fh else 'fwdHead=  -    ':<20} "
                  f"{('headAbove=%.2f' % st.mean(ha)) if ha else ''}")
    for tgt in ["forward_head", "look_down", "slouch"]:
        sfh = sep(byl["good"]["fh"], byl[tgt]["fh"])
        sha = sep(byl["good"]["ha"], byl[tgt]["ha"])
        if sfh is not None or sha is not None:
            line = f"  good→{tgt:<13}"
            if sfh is not None:
                line += f" fwdHead Δ={sfh:+.2f}"
            if sha is not None:
                line += f"  headAbove Δ={sha:+.2f}"
            print(line)


for cam, name in [("front", "FaceTime 0°"), ("side0", "BRIO"), ("side1", "iPhone")]:
    summarize(cam, name)
print("\nΔ = separation in std-devs vs 'good' (|Δ|>1.5 = usable signal). "
      "positive fwdHead Δ = posture pushes the ear forward.")
