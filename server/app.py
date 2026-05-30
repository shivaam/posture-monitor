# PostureMonitor MediaPipe server. Runs locally; the macOS app POSTs camera
# frames to /posture and gets back shoulders + posture metrics + landmarks.
#
#   cd server && ../.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000
# or: ./run.sh

from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse

import pose_engine
import placement

app = FastAPI(title="posture-monitor")


@app.get("/health")
def health():
    return {"ok": True, "model": pose_engine.MODEL}


@app.post("/posture")
async def posture(file: UploadFile = File(...)):
    data = await file.read()
    try:
        return pose_engine.posture(data)
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.post("/check_placement")
async def check_placement(file: UploadFile = File(...), view: str = Form("side")):
    """Ask a vision LLM whether the (side/front) camera is positioned well, and
    return plain guidance the app shows the user. No hand-coded geometry."""
    data = await file.read()
    try:
        return placement.check(data, view)
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.post("/judge")
async def judge(front: UploadFile = File(...), side: UploadFile = File(None)):
    """Lightweight periodic posture judgment: posture + confidence + side_usable.
    Used to gate alerts and decide whether the side camera is trustworthy."""
    fb = await front.read()
    sb = await side.read() if side is not None else None
    try:
        return placement.judge(fb, sb)
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.post("/assess_setup")
async def assess_setup(front: UploadFile = File(...), side: UploadFile = File(None)):
    """Two-camera setup diagnosis: the vision LLM looks at the front (+ optional
    side) frame and explains why the setup works / what's wrong right now."""
    fb = await front.read()
    sb = await side.read() if side is not None else None
    try:
        return placement.assess(fb, sb)
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})
