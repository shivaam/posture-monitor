"""llm_eval.py — measure how accurate the vision LLM actually is at detecting
slouch, using the ground-truth-labeled frames from the app's guided Test.

We pick one 'good' frame as the calibrated BASELINE, then ask the LLM to compare
each other labeled frame to it ("is this person slouching vs the reference?") and
score the verdict against the true label. Gives a real accuracy number to compare
against the 88% heuristic — evidence, not vibes.

    python llm_eval.py            # front camera only
    python llm_eval.py --side     # front + side[0] frames together
"""
import base64
import glob
import json
import os
import re
import sys

import anthropic

LAB = os.path.expanduser("~/Movies/PostureMonitor/labeled")
MODEL = os.environ.get("POSTURE_VISION_MODEL", "claude-sonnet-4-20250514")
client = anthropic.Anthropic(api_key="local-test", base_url="http://localhost:42069/v1")


def img(path):
    return {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
            "data": base64.b64encode(open(path, "rb").read()).decode()}}


def label_of(path):
    m = re.search(r"_(good|slouch|normal)_", os.path.basename(path))
    return m.group(1) if m else "?"


def stamp_of(path):
    m = re.search(r"_(\d{8}-\d{6}-\d{3})\.jpg", path)
    return m.group(1) if m else ""


PROMPT = (
    "Image 1 is a person at their desk sitting in their CALIBRATED UPRIGHT posture "
    "(the reference). Image 2 is the SAME person a moment later. Compared to the "
    "reference, is the person now SLOUCHING — spine rounded, head/shoulders dropped "
    "or pushed forward? Ignore brief glances down if the back is still straight. "
    'Reply ONLY JSON: {"slouching": true|false, "confidence": 0.0-1.0, "note":"<=8 words"}.'
)


def judge(baseline_imgs, cur_imgs):
    content = [{"type": "text", "text": "REFERENCE (upright):"}] + baseline_imgs
    content += [{"type": "text", "text": "CURRENT:"}] + cur_imgs
    content += [{"type": "text", "text": PROMPT}]
    msg = client.messages.create(model=MODEL, max_tokens=120,
                                 messages=[{"role": "user", "content": content}])
    txt = msg.content[0].text if msg.content else ""
    m = re.search(r"\{.*\}", txt, re.S)
    try:
        return json.loads(m.group(0)) if m else {}
    except Exception:
        return {}


def main():
    use_side = "--side" in sys.argv
    fronts = sorted(glob.glob(os.path.join(LAB, "front_*.jpg")))
    good = [f for f in fronts if label_of(f) == "good"]
    if len(good) < 2:
        print("need >=2 good frames; run the Test first."); return
    baseline = good[0]
    base_stamp = stamp_of(baseline)

    def sides(stamp):
        return sorted(glob.glob(os.path.join(LAB, f"side0_*_{stamp}.jpg")))

    base_imgs = [img(baseline)] + ([img(s) for s in sides(base_stamp)] if use_side else [])

    evalset = [f for f in fronts if f != baseline and label_of(f) in ("good", "slouch")]
    print(f"baseline={os.path.basename(baseline)}  eval={len(evalset)} frames  side={'on' if use_side else 'off'}\n")

    tp = tn = fp = fn = 0
    for f in evalset:
        true_slouch = (label_of(f) == "slouch")
        cur = [img(f)] + ([img(s) for s in sides(stamp_of(f))] if use_side else [])
        v = judge(base_imgs, cur)
        pred = bool(v.get("slouching", False))
        ok = pred == true_slouch
        if true_slouch and pred: tp += 1
        elif true_slouch and not pred: fn += 1
        elif not true_slouch and pred: fp += 1
        else: tn += 1
        print(f"  {label_of(f):<7} -> LLM slouch={str(pred):<5} conf={v.get('confidence','?')}  {'OK' if ok else 'WRONG'}  {v.get('note','')}")

    n = tp + tn + fp + fn
    acc = 100 * (tp + tn) // max(1, n)
    print(f"\n=== LLM accuracy: {acc}%  ({tp+tn}/{n})   TP={tp} TN={tn} FP={fp} FN={fn} ===")
    if tp + fn:
        print(f"slouch recall (caught real slouches): {100*tp//(tp+fn)}%   "
              f"false-alarm rate on upright: {100*fp//max(1,fp+tn)}%")
    print("compare vs the simple heuristic (mpHeadAbove): 88%")


if __name__ == "__main__":
    main()
