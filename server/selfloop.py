"""selfloop.py — the SELF-TUNING LOOP optimizer.

The app runs a vision LLM every ~30s and writes, per sample, the algorithm's raw
metrics + its own call PAIRED with the LLM's ground-truth posture, to
~/Movies/PostureMonitor/loop/dataset.jsonl. This script is the optimizer half:

  1. Build a confusion matrix (app vs LLM) — where do we disagree?
  2. Detect SYSTEMATIC errors:
       - turn -> false "leaning"  (app=leaning, LLM=good, shoulders foreshortened)
       - distance too insensitive (LLM=too_close but app distance bar still full)
       - lean over-sensitive       (app=leaning, LLM=good, facing forward)
  3. Grid-search thresholds (sensitivity / tilt / proximity) to best match the LLM.
  4. Print a report; with --write, update ~/.posturemonitor.json (the app picks it
     up next launch). --watch re-runs every few minutes as data accumulates.

    python selfloop.py            # analyze + recommend
    python selfloop.py --write     # also apply tuned thresholds
    python selfloop.py --watch 300 # loop every 300s (use with --write to auto-tune)
"""
import json
import os
import sys
import time

LOOP_DIR = os.path.expanduser("~/Movies/PostureMonitor/loop")
DATASET = os.path.join(LOOP_DIR, "dataset.jsonl")
CONFIG = os.path.expanduser("~/.posturemonitor.json")

SENS = [0.78, 0.80, 0.82, 0.85, 0.88, 0.90]
TILT = [5, 7, 9, 11, 14]
MARGIN = [0.08, 0.10, 0.12, 0.14, 0.18]

BAD = {"slumping", "leaning", "forward_head", "rounded_shoulders", "too_close"}


def load(min_conf=0.6):
    if not os.path.exists(DATASET):
        return []
    rows = []
    for ln in open(DATASET):
        try:
            r = json.loads(ln)
        except Exception:
            continue
        if r.get("llm_confidence", 0) >= min_conf and r.get("llm_posture", "unknown") != "unknown":
            rows.append(r)
    return rows


def classify(headRatio, tiltDev, distRatio, turned, sens, tilt, margin):
    """Mirror the app's logic (incl. the rotation guard) with candidate thresholds."""
    if distRatio > 1 + margin:
        return "too_close"
    if headRatio < sens:
        return "slumping"
    if (not turned) and abs(tiltDev) > tilt:
        return "leaning"
    return "good"


def is_bad(label):
    return label in BAD


def confusion(rows):
    """app-status vs llm-posture, collapsed to good/bad."""
    tp = fp = tn = fn = 0
    for r in rows:
        app_bad = is_bad(r.get("status", "good"))
        llm_bad = is_bad(r.get("llm_posture", "good"))
        if llm_bad and app_bad: tp += 1
        elif llm_bad and not app_bad: fn += 1
        elif not llm_bad and app_bad: fp += 1
        else: tn += 1
    return tp, fp, tn, fn


def systematic(rows):
    findings = []
    # turn -> false leaning
    turn_fp = [r for r in rows if r.get("status") == "leaning"
               and not is_bad(r.get("llm_posture", "good"))
               and (r.get("turned") or r.get("shoulderWRatio", 1) < 0.85)]
    lean_fp = [r for r in rows if r.get("status") == "leaning" and not is_bad(r.get("llm_posture", "good"))]
    if lean_fp:
        share = 100 * len(turn_fp) // max(1, len(lean_fp))
        findings.append(f"LEAN false-positives: {len(lean_fp)} (of which {share}% while TURNED — rotation guard should catch these)")
    # distance too insensitive: LLM says too_close but app distance bar still high
    dist_miss = [r for r in rows if r.get("llm_posture") == "too_close" and r.get("distFrac", 1) > 0.9]
    close_n = [r for r in rows if r.get("llm_posture") == "too_close"]
    if close_n:
        findings.append(f"DISTANCE: LLM flagged too_close {len(close_n)}x; app distance bar still >0.9 in {len(dist_miss)} -> proximity too insensitive, lower margin")
    # slump misses
    slump_miss = [r for r in rows if r.get("llm_posture") == "slumping" and r.get("headFrac", 1) > 0.9]
    if slump_miss:
        findings.append(f"SLUMP: {len(slump_miss)} frames LLM=slumping but app head bar >0.9 -> raise sensitivity")
    # SCORE too harsh: LLM says good but the score is low — name the culprit dimension
    harsh = [r for r in rows if not is_bad(r.get("llm_posture", "good")) and r.get("score", 100) < 80]
    if harsh:
        fracs = ("headFrac", "leanFrac", "distFrac", "sideFrac")
        culprit = {}
        for r in harsh:
            lo = min(fracs, key=lambda k: r.get(k, 1))
            culprit[lo] = culprit.get(lo, 0) + 1
        worst = sorted(culprit.items(), key=lambda x: -x[1])
        findings.append(f"SCORE too harsh: {len(harsh)} frames LLM=good but score<80; culprit dimension(s): " +
                        ", ".join(f"{k}×{v}" for k, v in worst) + " -> loosen that dimension's deadzone/threshold")
    return findings


def grid_search(rows):
    best = None
    for s in SENS:
        for t in TILT:
            for m in MARGIN:
                agree = 0
                for r in rows:
                    pred = classify(r.get("headRatio", 1), r.get("tiltDev", 0), r.get("distRatio", 1),
                                    bool(r.get("turned")), s, t, m)
                    if is_bad(pred) == is_bad(r.get("llm_posture", "good")):
                        agree += 1
                acc = agree / max(1, len(rows))
                if best is None or acc > best[0]:
                    best = (acc, s, t, m)
    return best


def write_config(sens, tilt, margin):
    cfg = {}
    if os.path.exists(CONFIG):
        try:
            cfg = json.load(open(CONFIG))
        except Exception:
            cfg = {}
    cfg.update({"sensitivity": round(sens, 3), "tiltThresh": float(tilt), "proximityMargin": round(margin, 3)})
    json.dump(cfg, open(CONFIG, "w"), indent=2)
    print(f"  -> wrote tuned thresholds to {CONFIG} (app picks them up next launch)")


def run_once(write):
    rows = load()
    if not rows:
        print("no confident labeled samples yet — let the app run (it logs a sample every ~30s).")
        return
    tp, fp, tn, fn = confusion(rows)
    n = len(rows)
    agree = 100 * (tp + tn) // n
    print(f"\n=== self-loop over {n} LLM-labeled samples ===")
    print(f"agreement good/bad: {agree}%   (TP={tp} FP={fp} TN={tn} FN={fn})")
    print("\nsystematic issues:")
    for f in systematic(rows) or ["  (none detected)"]:
        print("  -", f)
    best = grid_search(rows)
    print(f"\nbest thresholds vs LLM: sensitivity={best[1]} tilt={best[2]}deg proximity={best[3]}  (agreement {best[0]*100:.0f}%)")
    if write:
        write_config(best[1], best[2], best[3])
    else:
        print("  (re-run with --write to apply)")


def main():
    write = "--write" in sys.argv
    if "--watch" in sys.argv:
        i = sys.argv.index("--watch")
        interval = int(sys.argv[i + 1]) if len(sys.argv) > i + 1 else 300
        print(f"watching {DATASET} every {interval}s (write={write}) — Ctrl-C to stop")
        while True:
            run_once(write)
            time.sleep(interval)
    else:
        run_once(write)


if __name__ == "__main__":
    main()
