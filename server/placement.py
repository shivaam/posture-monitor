"""placement.py — use a VISION LLM to judge whether a posture camera is
positioned well, instead of hand-coding geometric heuristics.

Given a frame and which view it should be ("side" or "front"), Claude *looks* at
it and returns plain guidance the app shows the user ("move the camera lower",
"turn to your left", "good"). This is the "lean on vision LLMs" approach — we
don't have to write a full placement algorithm; the model is good at this.

Uses the local Anthropic proxy by default (no key needed), same as vision_label.
"""
import base64
import json
import os
import re

import anthropic

MODEL = os.environ.get("POSTURE_VISION_MODEL", "claude-sonnet-4-20250514")

_client = None


def client():
    global _client
    if _client is None:
        # Local Anthropic proxy — ambient ANTHROPIC_* env is ignored on purpose
        # (it would hijack the dummy key). Edit here to use the real API.
        _client = anthropic.Anthropic(api_key="local-test", base_url="http://localhost:42069/v1")
    return _client


SIDE_PROMPT = (
    "This is a frame from a webcam the user is trying to place to the SIDE of "
    "themselves while sitting at a desk, to capture their PROFILE for posture "
    "monitoring. A GOOD side view shows the person side-on so the EAR and the "
    "SHOULDER are both visible in profile (we measure how far the ear sits ahead "
    "of the shoulder to detect forward-head / rounded shoulders). "
    'Reply with ONLY JSON: {"ok": true|false, '
    '"position": "good|no_person|facing_camera|back_to_camera|too_high|too_low|too_far|too_close|partial", '
    '"guidance": "<one short friendly sentence: how to move the camera or themselves>"}. '
    "ok=true ONLY if it is a usable side profile showing head and shoulder. "
    "Keep guidance under 16 words."
)

FRONT_PROMPT = (
    "This is a frame from a webcam the user is placing in FRONT of themselves at "
    "a desk for posture monitoring. A GOOD front view is roughly eye-level and "
    "shows the head and both shoulders centered, not too close. "
    'Reply with ONLY JSON: {"ok": true|false, '
    '"position": "good|no_person|too_high|too_low|too_far|too_close|off_center|partial", '
    '"guidance": "<one short friendly sentence: how to move the camera or themselves>"}. '
    "Keep guidance under 16 words."
)


def _img(b):
    return {"type": "image", "source": {
        "type": "base64", "media_type": "image/jpeg", "data": base64.b64encode(b).decode()}}


def _json(txt):
    m = re.search(r"\{.*\}", txt, re.S)
    try:
        return json.loads(m.group(0)) if m else {}
    except Exception:
        return {}


def check(image_bytes, view="side"):
    prompt = SIDE_PROMPT if view == "side" else FRONT_PROMPT
    msg = client().messages.create(
        model=MODEL, max_tokens=160,
        messages=[{"role": "user", "content": [_img(image_bytes), {"type": "text", "text": prompt}]}])
    txt = msg.content[0].text if msg.content else ""
    d = _json(txt)
    return {
        "ok": bool(d.get("ok", False)),
        "position": d.get("position", "unknown"),
        "guidance": d.get("guidance") or (txt[:80] if txt else "no response"),
    }


ASSESS_PROMPT = (
    "You are an expert helping a person set up a desk-posture monitor that uses "
    "TWO cameras. Image 1 is the FRONT camera (should be ~eye level and show the "
    "face and both shoulders). Image 2, if present, is the SIDE camera (should "
    "show the PROFILE — ear and shoulder visible side-on — so forward-head and "
    "rounded shoulders can be measured; a front camera physically cannot see those). "
    "Look at the actual images and reason about the setup. "
    'Reply with ONLY JSON: {'
    '"front_ok": true|false, "side_ok": true|false, '
    '"posture": "good|slumping|leaning|forward_head|rounded_shoulders|too_close|unknown", '
    '"problem": "<the single biggest issue with the camera setup or posture RIGHT NOW, <=12 words>", '
    '"fix": "<one concrete action to improve it, <=14 words>", '
    '"explanation": "<2-4 sentences in plain language: why each camera will or will not work, '
    'and what we can and cannot measure with this setup right now>"}. '
    "If only the front image is given, set side_ok=false and explain that adding a "
    "side camera (e.g. an iPhone via Continuity Camera) unlocks forward-head detection."
)


def assess(front_bytes, side_bytes=None):
    """Two-camera setup diagnosis: the LLM looks at front (+ optional side) and
    explains in plain language why the setup works / what's wrong right now."""
    content = [{"type": "text", "text": "Image 1 — FRONT camera view:"}, _img(front_bytes)]
    if side_bytes:
        content += [{"type": "text", "text": "Image 2 — SIDE camera view:"}, _img(side_bytes)]
    else:
        content += [{"type": "text", "text": "(No side camera connected.)"}]
    content.append({"type": "text", "text": ASSESS_PROMPT})
    msg = client().messages.create(
        model=MODEL, max_tokens=500,
        messages=[{"role": "user", "content": content}])
    txt = msg.content[0].text if msg.content else ""
    d = _json(txt)
    return {
        "front_ok": bool(d.get("front_ok", False)),
        "side_ok": bool(d.get("side_ok", False)),
        "posture": d.get("posture", "unknown"),
        "problem": d.get("problem", ""),
        "fix": d.get("fix", ""),
        "explanation": d.get("explanation") or (txt[:300] if txt else "no response"),
        "has_side": side_bytes is not None,
    }
