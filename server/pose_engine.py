# MediaPipe BlazePose engine for the stretch-lab Mac server.
#
# One heavy PoseLandmarker, created once and reused (it is NOT thread-safe in
# IMAGE mode, so callers must serialize via the module lock). Produces:
#   - joint angles (mirrors pose_mp.py / pose.swift exactly)
#   - per-joint visibility (the confidence analogue)
#   - a normalized silhouette PNG for onion-skin overlays
#   - a plausibility-based retake verdict (visibility is saturated on MediaPipe,
#     so the honest gate is angle sanity + required-joint presence, per the
#     mediapipe-vs-vision writeup)

import io
import math
import threading

import numpy as np
from PIL import Image, ImageOps
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision

MODEL = "pose_landmarker_heavy.task"

NOSE = 0
LEFT_SHOULDER, RIGHT_SHOULDER = 11, 12
LEFT_HIP, RIGHT_HIP = 23, 24
LEFT_KNEE, RIGHT_KNEE = 25, 26
LEFT_ANKLE, RIGHT_ANKLE = 27, 28

SINGLE = {
    "l_shoulder": LEFT_SHOULDER, "r_shoulder": RIGHT_SHOULDER,
    "l_hip": LEFT_HIP, "r_hip": RIGHT_HIP,
    "l_knee": LEFT_KNEE, "r_knee": RIGHT_KNEE,
    "l_ankle": LEFT_ANKLE, "r_ankle": RIGHT_ANKLE,
}

LEFT_EAR, RIGHT_EAR = 7, 8
LEFT_ELBOW, RIGHT_ELBOW = 13, 14
LEFT_WRIST, RIGHT_WRIST = 15, 16

# Shared joint vocabulary mirroring the iOS PoseJoint enum, so metrics computed
# here on the Mac port 1:1 to Swift later (same names, engine-agnostic).
NAMED = {
    "nose": NOSE,
    "leftEar": LEFT_EAR, "rightEar": RIGHT_EAR,
    "leftShoulder": LEFT_SHOULDER, "rightShoulder": RIGHT_SHOULDER,
    "leftElbow": LEFT_ELBOW, "rightElbow": RIGHT_ELBOW,
    "leftWrist": LEFT_WRIST, "rightWrist": RIGHT_WRIST,
    "leftHip": LEFT_HIP, "rightHip": RIGHT_HIP,
    "leftKnee": LEFT_KNEE, "rightKnee": RIGHT_KNEE,
    "leftAnkle": LEFT_ANKLE, "rightAnkle": RIGHT_ANKLE,
}

# Normalized silhouette canvas (portrait). Hip-center is anchored and the figure
# is scaled so shoulder->hip spans a fixed fraction of the height, so week-0 and
# today overlay directly regardless of camera distance.
CANVAS_W, CANVAS_H = 720, 1280
TORSO_TARGET_FRAC = 0.22  # shoulder-hip distance as fraction of canvas height

_lock = threading.Lock()
_landmarker = None


def _get_landmarker():
    global _landmarker
    if _landmarker is None:
        opts = vision.PoseLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=MODEL),
            running_mode=vision.RunningMode.IMAGE,
            min_pose_detection_confidence=0.3,
            num_poses=1,
            output_segmentation_masks=True)
        _landmarker = vision.PoseLandmarker.create_from_options(opts)
    return _landmarker


def angle_at(b, a, c):
    v1 = (a[0] - b[0], a[1] - b[1])
    v2 = (c[0] - b[0], c[1] - b[1])
    dot = v1[0] * v2[0] + v1[1] * v2[1]
    m = math.hypot(*v1) * math.hypot(*v2)
    if m == 0:
        return float("nan")
    return math.degrees(math.acos(max(-1, min(1, dot / m))))


def to_floor(a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    return abs(math.degrees(math.atan2(dy, dx))) % 180


def _load_upright(image_bytes):
    img = ImageOps.exif_transpose(Image.open(io.BytesIO(image_bytes)).convert("RGB"))
    return img


def analyze(image_bytes, pose_kind=None):
    """Run pose. Returns dict with angles, joint_confidence, verdict.

    pose_kind tunes the retake gate to the benchmark pose (which limb/angle
    matters). Unknown/None -> generic gate.
    """
    img = _load_upright(image_bytes)
    W, H = img.size
    arr = np.asarray(img)
    mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=arr)

    with _lock:
        lmk = _get_landmarker()
        res = lmk.detect(mp_img)

    if not res.pose_landmarks:
        return {"person_detected": False, "verdict": "retake",
                "reasons": ["No person detected — fit your whole body in frame."],
                "image_wh": [W, H]}

    lm = res.pose_landmarks[0]

    def pt(idx, vis_min=0.0):
        p = lm[idx]
        if p.visibility < vis_min:
            return None
        return (p.x * W, p.y * H, p.visibility)

    jc = {}
    sh_l, sh_r = lm[LEFT_SHOULDER], lm[RIGHT_SHOULDER]
    hip_l, hip_r = lm[LEFT_HIP], lm[RIGHT_HIP]
    jc["neck"] = round(min(sh_l.visibility, sh_r.visibility), 2)
    for n, idx in SINGLE.items():
        jc[n] = round(lm[idx].visibility, 2)
    jc["root"] = round(min(hip_l.visibility, hip_r.visibility), 2)

    angles = {}
    VIS = 0.05
    sides = [("left", LEFT_SHOULDER, LEFT_HIP, LEFT_KNEE, LEFT_ANKLE),
             ("right", RIGHT_SHOULDER, RIGHT_HIP, RIGHT_KNEE, RIGHT_ANKLE)]
    for side, sh, hip, knee, ankle in sides:
        s, h, k, a = pt(sh, VIS), pt(hip, VIS), pt(knee, VIS), pt(ankle, VIS)
        if s and h and k:
            angles[f"{side}_hip_flexion_deg"] = round(angle_at(h, s, k))
        if h and k and a:
            angles[f"{side}_knee_deg"] = round(angle_at(k, h, a))
        if h and a:
            angles[f"{side}_leg_to_floor_deg"] = round(to_floor(h, a))

    # ASLR (lying straight-leg raise): the raised leg's angle measured RELATIVE to
    # the grounded leg, not the image axis. Both lines share camera roll, so the
    # difference cancels tilt — a propped phone leaning a few degrees no longer
    # masquerades as flexibility change. We also auto-pick which leg is raised
    # (the one with the larger floor angle) so the user never has to remember a side.
    lf_l = angles.get("left_leg_to_floor_deg")
    lf_r = angles.get("right_leg_to_floor_deg")
    raised_side = None
    if lf_l is not None and lf_r is not None:
        raised_side = "left" if lf_l >= lf_r else "right"
    elif lf_l is not None:
        raised_side = "left"
    elif lf_r is not None:
        raised_side = "right"
    if raised_side is not None:
        down_side = "right" if raised_side == "left" else "left"
        rl = angles.get(f"{raised_side}_leg_to_floor_deg")
        dl = angles.get(f"{down_side}_leg_to_floor_deg")
        if rl is not None:
            angles["aslr_raise_deg"] = round(abs(rl - dl)) if dl is not None else round(rl)

    # Normalized landmarks (0..1, y down) for client-side drawing of the skeleton,
    # angle arc, and the progress "angle fan" — no second round-trip / no baked PNG.
    landmarks_out = {name: [round(lm[i].x, 4), round(lm[i].y, 4), round(lm[i].visibility, 2)]
                     for name, i in NAMED.items()}

    overall = round(float(np.mean([lm[i].visibility for i in range(33)])), 2)
    verdict, reasons = _gate(lm, angles, jc, pose_kind, W, H)

    return {
        "person_detected": True,
        "overall_confidence": overall,
        "joint_confidence": jc,
        "angles": angles,
        "raised_side": raised_side,
        "landmarks": landmarks_out,
        "verdict": verdict,
        "reasons": reasons,
        "image_wh": [W, H],
    }


def landmarks(image_bytes):
    """Return a dict {jointName: (x, y, visibility)} in normalized 0..1 image
    coords (y down), using the shared NAMED vocabulary. None if no person.
    Engine-agnostic shape so toy logic built on it ports straight to Swift."""
    img = _load_upright(image_bytes)
    arr = np.asarray(img)
    mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=arr)
    with _lock:
        lmk = _get_landmarker()
        res = lmk.detect(mp_img)
    if not res.pose_landmarks:
        return None
    lm = res.pose_landmarks[0]
    return {name: (lm[i].x, lm[i].y, lm[i].visibility) for name, i in NAMED.items()}


def posture(image_bytes, vis_min=0.3):
    """Posture metrics for the desk monitor (MediaPipe side of the dual-engine
    compare). Normalized coords are 0..1, y DOWN.

      shoulders_found  : both shoulders visible enough to trust
      head_above       : (shoulder_mid_y - nose_y) / shoulder_width — bigger when
                         the head sits higher above the shoulders; drops on slump
      shoulder_tilt_deg: shoulder-line angle from horizontal (+ = right lower)
      shoulder_width   : |L.x - R.x| (proximity proxy; grows as you lean in)
      landmarks        : the NAMED dict (for the client overlay, if wanted)
    """
    j = landmarks(image_bytes)
    if j is None:
        return {"person_detected": False}
    out = {"person_detected": True, "shoulders_found": False, "landmarks": j}
    ls, rs, nose = j.get("leftShoulder"), j.get("rightShoulder"), j.get("nose")
    if ls and rs and min(ls[2], rs[2]) >= vis_min:
        out["shoulders_found"] = True
        width = abs(ls[0] - rs[0]) or 1e-4
        out["shoulder_width"] = round(width, 4)
        out["shoulder_tilt_deg"] = round(math.degrees(math.atan2(rs[1] - ls[1], width)), 1)
        if nose:
            sh_mid_y = (ls[1] + rs[1]) / 2
            out["head_above"] = round((sh_mid_y - nose[1]) / width, 3)
    return out


def _gate(lm, angles, jc, pose_kind, W, H):
    """Plausibility-first retake gate. MediaPipe visibility saturates near 1.0,
    so we lean on geometry: are required joints in-frame, are angles physically
    sane, is framing full-body."""
    reasons = []

    # full-body framing: ankles and shoulders should be inside the frame margin
    def inframe(idx, margin=0.02):
        p = lm[idx]
        return margin < p.x < 1 - margin and margin < p.y < 1 - margin

    if not (inframe(LEFT_ANKLE) or inframe(RIGHT_ANKLE)):
        reasons.append("Feet near/out of frame — step back so ankles are visible.")
    if not (inframe(LEFT_SHOULDER) and inframe(RIGHT_SHOULDER)):
        reasons.append("Shoulders cut off — fit your upper body in frame.")

    # angle sanity
    for k, v in angles.items():
        if k.endswith("_deg") and not (0 <= v <= 185):
            reasons.append(f"Implausible {k.replace('_', ' ')} ({v}°).")

    # pose-specific near-limb confidence: at least one side's knee chain present
    near_knee = max(jc.get("l_knee", 0), jc.get("r_knee", 0))
    if near_knee < 0.5:
        reasons.append("Legs hard to read — make sure your lower body is well-lit and unobstructed.")

    # ASLR validity: the metric is only meaningful side-on, lying, raised knee straight.
    if pose_kind == "aslr":
        # both legs must be visible — the grounded leg is the tilt-invariant reference
        if angles.get("left_leg_to_floor_deg") is None or angles.get("right_leg_to_floor_deg") is None:
            reasons.append("Get both legs in frame — lie side-on with your whole body visible.")
        lf_l = angles.get("left_leg_to_floor_deg", 0)
        lf_r = angles.get("right_leg_to_floor_deg", 0)
        raised = "left" if lf_l >= lf_r else "right"
        # raised knee must be near-straight (bent knee fakes a higher angle)
        knee = angles.get(f"{raised}_knee_deg")
        if knee is not None and knee < 155:
            reasons.append("Keep the raised knee straight — it looks bent.")
        # side-on: shoulders should nearly overlap horizontally vs torso length
        sh_l, sh_r = lm[LEFT_SHOULDER], lm[RIGHT_SHOULDER]
        hip_l, hip_r = lm[LEFT_HIP], lm[RIGHT_HIP]
        shoulder_dx = abs(sh_l.x - sh_r.x) * W
        torso = math.hypot(((sh_l.x + sh_r.x) - (hip_l.x + hip_r.x)) / 2 * W,
                           ((sh_l.y + sh_r.y) - (hip_l.y + hip_r.y)) / 2 * H)
        if torso > 1 and shoulder_dx / torso > 0.6:
            reasons.append("Turn side-on to the camera so one shoulder hides the other.")
        # lying: the grounded (lower) leg should rest near the floor
        if min(lf_l, lf_r) > 35:
            reasons.append("Lie flat and keep your resting leg down on the floor.")

    verdict = "ok" if not reasons else "retake"
    return verdict, reasons


def silhouette_png(image_bytes):
    """Normalized white-on-transparent silhouette for onion-skin overlay.
    Anchors hip-center and scales by torso length onto a fixed canvas so two
    shots taken weeks apart line up. Returns PNG bytes, or None if no person."""
    img = _load_upright(image_bytes)
    W, H = img.size
    arr = np.asarray(img)
    mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=arr)

    with _lock:
        lmk = _get_landmarker()
        res = lmk.detect(mp_img)

    if not res.pose_landmarks or not res.segmentation_masks:
        return None

    mask = res.segmentation_masks[0].numpy_view()  # float32 HxW(x1), 0..1
    if mask.ndim == 3:
        mask = mask[..., 0]
    # mask is at the model's working resolution; resize to image size
    mask_img = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8)).resize((W, H), Image.BILINEAR)
    m = np.asarray(mask_img)

    # white silhouette, alpha = mask
    rgba = np.zeros((H, W, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = m
    sil = Image.fromarray(rgba, "RGBA")

    lm = res.pose_landmarks[0]
    hip_x = (lm[LEFT_HIP].x + lm[RIGHT_HIP].x) / 2 * W
    hip_y = (lm[LEFT_HIP].y + lm[RIGHT_HIP].y) / 2 * H
    sh_x = (lm[LEFT_SHOULDER].x + lm[RIGHT_SHOULDER].x) / 2 * W
    sh_y = (lm[LEFT_SHOULDER].y + lm[RIGHT_SHOULDER].y) / 2 * H
    torso = math.hypot(sh_x - hip_x, sh_y - hip_y)
    if torso < 1:
        return None

    scale = (TORSO_TARGET_FRAC * CANVAS_H) / torso
    new_w, new_h = max(1, int(W * scale)), max(1, int(H * scale))
    sil = sil.resize((new_w, new_h), Image.BILINEAR)

    # hip-center in scaled image -> place at canvas center
    cx, cy = hip_x * scale, hip_y * scale
    canvas = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    ox = int(CANVAS_W / 2 - cx)
    oy = int(CANVAS_H / 2 - cy)
    canvas.alpha_composite(sil, (ox, oy))

    buf = io.BytesIO()
    canvas.save(buf, format="PNG")
    return buf.getvalue()
