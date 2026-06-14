"""vision_label.py — INDEPENDENT posture labels from Claude vision, diffed
against the app's own labels.

This breaks the weak-supervision problem in the self-dev loop: instead of
trusting the app's thresholds, Claude *looks* at each frame and judges posture,
and we compare. Where they disagree is exactly where to tune.

    ../.venv/bin/python vision_label.py <clip.mp4> [secs_between=2.0]

Needs `anthropic` + `opencv-python`. Uses the local Anthropic proxy by default
(no key); set ANTHROPIC_API_KEY / ANTHROPIC_BASE_URL / POSTURE_VISION_MODEL to
use the real API.
"""
import base64
import json
import os
import re
import sys

import cv2
import anthropic

PROMPT = (
    "You are judging a person's SEATED DESK posture from one webcam frame. "
    'Reply with ONLY JSON: {"posture":"good|slumping|leaning|too_close",'
    '"confidence":0-1,"note":"<=8 words"}. '
    "good = upright and centered; slumping = head dropped or hunched forward; "
    "leaning = tilted/listing to one side; too_close = face fills much of the frame."
)


def label(client, model, jpg_bytes):
    b = base64.b64encode(jpg_bytes).decode()
    msg = client.messages.create(model=model, max_tokens=120, messages=[{"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b}},
        {"type": "text", "text": PROMPT}]}])
    txt = msg.content[0].text
    m = re.search(r"\{.*\}", txt, re.S)
    try:
        return json.loads(m.group(0)) if m else {"posture": "?", "note": txt[:40]}
    except Exception:
        return {"posture": "?", "note": txt[:40]}


def app_status_at(samples, t):
    if not samples:
        return "?"
    best = min(samples, key=lambda s: abs(s.get("t", 1e9) - t))
    return best.get("status", "?")


def main():
    if len(sys.argv) < 2:
        print("usage: vision_label.py <clip.mp4> [secs_between=2.0]"); return
    path = sys.argv[1]
    every = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0

    samples = []
    sp = path.rsplit(".", 1)[0] + ".events.jsonl"
    if os.path.exists(sp):
        for ln in open(sp):
            try:
                e = json.loads(ln)
            except Exception:
                continue
            if e.get("type") == "sample":
                samples.append(e)

    # Local Anthropic proxy (no real key needed). Ambient ANTHROPIC_* env vars are
    # ignored on purpose — they'd hijack the dummy key. To use the real API, edit here.
    client = anthropic.Anthropic(api_key="local-test", base_url="http://localhost:42069/v1")
    model = os.environ.get("POSTURE_VISION_MODEL", "claude-sonnet-4-20250514")

    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    step = max(1, int(fps * every))
    i, rows = 0, []
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if i % step == 0:
            _, buf = cv2.imencode(".jpg", frame)
            v = label(client, model, buf.tobytes())
            t = round(i / fps, 1)
            app = app_status_at(samples, t)
            cp = v.get("posture", "?")
            # coarse agreement: do Claude and the app agree it's good vs not-good?
            agree = (cp == "good") == (app in ("good", "settling"))
            rows.append((t, cp, app, agree))
            print("t=%5.1fs  claude=%-10s app=%-10s %s   %s" % (
                t, cp, app, "OK  " if agree else "DIFF", v.get("note", "")))
        i += 1
    cap.release()
    if rows:
        ag = sum(1 for r in rows if r[2] != "?" and r[3])
        cmp = sum(1 for r in rows if r[2] != "?")
        if cmp:
            print("\ngood/bad agreement with app: %d/%d (%d%%)" % (ag, cmp, 100 * ag // cmp))
        else:
            print("\n(no app sidecar to compare against — Claude labels only)")


if __name__ == "__main__":
    main()
