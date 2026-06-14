"""labeled_analyze.py — find the SINGLE simplest metric that separates upright
from slouch, using the ground-truth-labeled data from the app's guided Test mode.

The app's 🎯 Test prompts the user through postures ("sit tall" / "slouch") and
writes, per HOLD second, every candidate metric labeled by the prompt to
~/Movies/PostureMonitor/labeled/dataset.jsonl. This script ranks each metric by
how cleanly it separates good vs slouch (separation = |Δmean| / pooled-std),
picks the best, finds the threshold + direction, and reports accuracy. That
becomes the new, simple slouch heuristic — no patches.

    python labeled_analyze.py
"""
import json
import os
import statistics as st

DATA = os.path.expanduser("~/Movies/PostureMonitor/labeled/dataset.jsonl")


def load():
    rows = []
    if not os.path.exists(DATA):
        return rows
    for ln in open(DATA):
        try:
            rows.append(json.loads(ln))
        except Exception:
            pass
    return rows


def numeric_keys(rows):
    keys = set()
    for r in rows:
        for k, v in r.items():
            if k in ("label", "t", "mpShoulders"):
                continue
            if isinstance(v, (int, float)):
                keys.add(k)
    return sorted(keys)


def main():
    rows = load()
    if not rows:
        print("no labeled data yet — click 🎯 Test in the app and follow the prompts first.")
        return
    good = [r for r in rows if r.get("label") == "good"]
    slouch = [r for r in rows if r.get("label") == "slouch"]
    print(f"{len(rows)} samples: good={len(good)} slouch={len(slouch)} "
          f"normal={sum(1 for r in rows if r.get('label')=='normal')}")
    if len(good) < 2 or len(slouch) < 2:
        print("need at least 2 good and 2 slouch samples — run the Test again.")
        return

    ranked = []
    for k in numeric_keys(rows):
        g = [r[k] for r in good if isinstance(r.get(k), (int, float))]
        s = [r[k] for r in slouch if isinstance(r.get(k), (int, float))]
        if len(g) < 2 or len(s) < 2:
            continue
        mg, ms = st.mean(g), st.mean(s)
        pooled = (st.pstdev(g) + st.pstdev(s)) / 2 or 1e-9
        sep = abs(mg - ms) / pooled
        thr = (mg + ms) / 2
        # direction: does slouch read LOWER or HIGHER than good?
        slouch_lower = ms < mg
        # accuracy with this threshold + direction
        correct = 0
        for r in good + slouch:
            if not isinstance(r.get(k), (int, float)):
                continue
            pred_slouch = (r[k] < thr) if slouch_lower else (r[k] > thr)
            if pred_slouch == (r.get("label") == "slouch"):
                correct += 1
        acc = correct / (len(g) + len(s))
        ranked.append((sep, acc, k, mg, ms, thr, slouch_lower))

    ranked.sort(reverse=True)
    print("\nmetric separation (good vs slouch), best first:")
    print(f"  {'metric':<16} {'sep':>5} {'acc':>5}  good→slouch")
    for sep, acc, k, mg, ms, thr, lower in ranked:
        print(f"  {k:<16} {sep:>5.2f} {acc*100:>4.0f}%  {mg:+.3f} → {ms:+.3f}  (slouch={'lower' if lower else 'higher'}, thr={thr:.3f})")

    if ranked:
        best = ranked[0]
        print(f"\n>>> SIMPLEST SLOUCH HEURISTIC: slouch when `{best[2]}` "
              f"{'<' if best[6] else '>'} {best[5]:.3f}  (≈{best[1]*100:.0f}% on this data)")
        print("    Calibrate captures the 'good' value; alert when it crosses the threshold for a few seconds.")


if __name__ == "__main__":
    main()
