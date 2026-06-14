"""blur_faces.py — pixelate every face across a folder of frames (for sharing a
demo publicly). OpenCV Haar cascades (frontal + profile, both directions) + box
PERSISTENCE so a missed detection reuses the last boxes for a few frames.

Works on PNG frames (ffmpeg does video decode/encode, which is more portable than
relying on OpenCV's codecs):

    ffmpeg -i in.mp4 /tmp/in/f%05d.png
    python blur_faces.py /tmp/in /tmp/out
    ffmpeg -framerate FPS -i /tmp/out/f%05d.png ... out.mp4
"""
import glob
import os
import sys

import cv2

indir, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)

HC = cv2.data.haarcascades
front = cv2.CascadeClassifier(HC + "haarcascade_frontalface_default.xml")
alt = cv2.CascadeClassifier(HC + "haarcascade_frontalface_alt2.xml")
prof = cv2.CascadeClassifier(HC + "haarcascade_profileface.xml")


def detect(gray, W):
    out = []
    for c in (front, alt):
        for (x, y, w, h) in c.detectMultiScale(gray, 1.08, 4, minSize=(30, 30)):
            out.append((x, y, w, h))
    for (x, y, w, h) in prof.detectMultiScale(gray, 1.08, 4, minSize=(30, 30)):
        out.append((x, y, w, h))
    for (x, y, w, h) in prof.detectMultiScale(cv2.flip(gray, 1), 1.08, 4, minSize=(30, 30)):
        out.append((W - x - w, y, w, h))
    return out


files = sorted(glob.glob(os.path.join(indir, "*.png")))
recent, blurs = [], 0
for i, f in enumerate(files):
    frame = cv2.imread(f)
    H, W = frame.shape[:2]
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    boxes = []
    for (x, y, w, h) in detect(gray, W):
        px, py = int(w * 0.35), int(h * 0.5)
        boxes.append([max(0, x - px), max(0, y - py), min(W, x + w + px), min(H, y + h + py), 12])
    recent = [r for r in recent if r[4] > 1]
    for r in recent:
        r[4] -= 1
    recent = boxes + recent
    for x0, y0, x1, y1, _ in recent:
        roi = frame[y0:y1, x0:x1]
        if roi.size:
            sw, sh = max(1, (x1 - x0) // 10), max(1, (y1 - y0) // 10)
            frame[y0:y1, x0:x1] = cv2.resize(cv2.resize(roi, (sw, sh)), (x1 - x0, y1 - y0),
                                             interpolation=cv2.INTER_NEAREST)
            blurs += 1
    cv2.imwrite(os.path.join(outdir, os.path.basename(f)), frame)

print(f"frames={len(files)}  faceblurs={blurs}")
