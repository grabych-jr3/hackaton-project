import asyncio
import contextlib
import logging
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, UploadFile

from .analyzer import build_analyzer
from .config import get_settings
from .kafka_worker import run_worker
from .pipeline import analyze_bytes
from .schema import PhotoAnalyzed

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("vision")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    app.state.settings = settings
    app.state.analyzer = build_analyzer(settings.gemini_api_key, settings.gemini_model)
    stop = asyncio.Event()
    task = None
    if settings.kafka_enabled:
        task = asyncio.create_task(run_worker(app.state.analyzer, settings, stop))
    else:
        log.info("KAFKA_ENABLED=false -> consumer not started")
    yield
    stop.set()
    if task:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await task


app = FastAPI(title="vision-service", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok", "analyzer": app.state.analyzer.name,
            "kafka": app.state.settings.kafka_enabled}


@app.post("/analyze", response_model=PhotoAnalyzed)
async def analyze(file: UploadFile = File(...), catchId: str | None = None):
    """Debug endpoint: runs the same pipeline synchronously on an uploaded image."""
    data = await file.read()
    return await analyze_bytes(catchId or f"debug-{uuid.uuid4()}", data,
                               app.state.analyzer, app.state.settings)
