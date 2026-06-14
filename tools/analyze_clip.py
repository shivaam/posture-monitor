"""Offline analysis of a recorded posture clip — runs MediaPipe per sampled
frame, draws the skeleton, writes annotated PNGs + a metrics summary. Lets the
dev (or an AI) verify overlay alignment / tune thresholds from recorded video
without a live camera.

Needs opencv (`pip install opencv-python`) in addition to the server reqs.

    ../.venv/bin/python analyze_clip.py ~/Movies/PostureMonitor/clip_*.mp4 [secs_between=1.0]
"""
import json
import os
import sys

import cv2
import pose_engine

BONES = [("leftEar", "nose"), ("rightEar", "nose"), ("leftShoulder", "rightShoulder"),
         ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
         ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
         ("leftShoulder", "leftHip"), ("rightShoulder", "rightHip"), ("leftHip", "rightHip")]


def draw(frame, lms, W, H):
    def px(n):
        p = lms.get(n)
        if not p or p[2] < 0.3:
            return None
        return (int(p[0] * W), int(p[1] * H))
    for a, b in BONES:
        pa, pb = px(a), px(b)
        if pa and pb:
            cv2.line(frame, pa, pb, (0, 230, 120), 3)
    for n in lms:
        c = px(n)
        if c:
            cv2.circle(frame, c, 4, (0, 230, 120), -1)


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_clip.py <clip.mp4> [secs_between=1.0]"); return
    path = sys.argv[1]
    every = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    out = "/tmp/clip_analysis"
    os.makedirs(out, exist_ok=True)

    # Sidecar tells us the user's calibrated baseline ("where they started").
    events_path = path.rsplit(".", 1)[0] + ".events.jsonl"
    cal = None
    if os.path.exists(events_path):
        for ln in open(events_path):
            try:
                e = json.loads(ln)
            except Exception:
                continue
            if e.get("type") == "calibrate":
                cal = e
        if cal:
            print("calibration baseline @t=%ss: head=%s tilt=%s width=%s" % (
                cal.get("t"), cal.get("baseHead"), cal.get("baseTilt"), cal.get("baseWidth")))
        else:
            print("sidecar present but no calibration event")
    else:
        print("no sidecar events file (clip not from the app, or never calibrated)")
    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    step = max(1, int(fps * every))
    i = saved = 0
    rows = []
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if i % step == 0:
            H, W = frame.shape[:2]
            _, buf = cv2.imencode(".jpg", frame)
            res = pose_engine.posture(buf.tobytes())
            lms = res.get("landmarks", {})
            draw(frame, lms, W, H)
            txt = "t=%.1fs shoulders=%s head_above=%s tilt=%s" % (
                i / fps, res.get("shoulders_found"), res.get("head_above"), res.get("shoulder_tilt_deg"))
            cv2.putText(frame, txt, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 230, 120), 2)
            cv2.imwrite("%s/frame_%04d.png" % (out, saved), frame)
            saved += 1
            rows.append((i / fps, res.get("shoulders_found"), res.get("head_above"), res.get("shoulder_tilt_deg")))
        i += 1
    cap.release()
    print("analyzed %d frames, saved %d annotated -> %s" % (i, saved, out))
    sf = sum(1 for r in rows if r[1])
    print("shoulders found in %d/%d sampled frames" % (sf, len(rows)))
    ha = [r[2] for r in rows if r[2] is not None]
    if ha:
        print("head_above range %.2f .. %.2f" % (min(ha), max(ha)))


if __name__ == "__main__":
    main()
