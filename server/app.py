# PostureMonitor MediaPipe server. Runs locally; the macOS app POSTs camera
# frames to /posture and gets back shoulders + posture metrics + landmarks.
#
#   cd server && ../.venv/bin/python -m uvicorn app:app --host 0.0.0.0 --port 8000
# or: ./run.sh

from fastapi import FastAPI, UploadFile, File
from fastapi.responses import JSONResponse

import pose_engine

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
