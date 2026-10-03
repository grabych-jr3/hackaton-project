"""Full photo pipeline: preprocess -> AI -> validated photo.analyzed message."""
import asyncio
import logging
import os

from pydantic import ValidationError

from .analyzer import Analyzer
from .config import Settings
from .preprocess import preprocess
from .schema import AnalysisResult, GeminiAnswer, PhotoAnalyzed, PhotoSubmitted

log = logging.getLogger(__name__)

AI_RETRIES = 2  # retries after the first attempt (AI errors or invalid JSON)
REASON_FAILED = "AI niedostępne, użyj ankiety"
REASON_NOT_FOUND = "Nie znaleziono pliku zdjęcia"
REASON_IRRELEVANT = "Na zdjęciu nie widać bariery ani przejścia — sfotografuj miejsce"


async def analyze_bytes(catch_id: str, data: bytes, analyzer: Analyzer, settings: Settings,
                        retry_delay: float = 0.5) -> PhotoAnalyzed:
    pre = await asyncio.to_thread(
        preprocess, data, max_side=settings.max_side,
        blur_threshold=settings.blur_threshold, dark_threshold=settings.dark_threshold,
    )
    if not pre.ok:
        return PhotoAnalyzed(catchId=catch_id, status="REJECTED", phash=pre.phash, reason=pre.reason)

    last_err = "unknown"
    for attempt in range(1 + AI_RETRIES):
        try:
            raw = await analyzer.analyze(pre.jpeg)
            ans = GeminiAnswer.model_validate_json(raw)
        except ValidationError as e:
            last_err = f"invalid AI response: {e.error_count()} errors"
            log.warning("catch %s: attempt %d invalid response: %s", catch_id, attempt + 1, e)
        except Exception as e:
            last_err = f"AI error: {type(e).__name__}"
            log.warning("catch %s: attempt %d AI error: %s", catch_id, attempt + 1, e)
        else:
            if not ans.relevant:
                return PhotoAnalyzed(catchId=catch_id, status="REJECTED", phash=pre.phash,
                                     reason=ans.rejectReason or REASON_IRRELEVANT)
            result = AnalysisResult.model_validate(ans.model_dump(exclude={"relevant", "rejectReason"}))
            return PhotoAnalyzed(catchId=catch_id, status="OK", result=result, phash=pre.phash)
        if attempt < AI_RETRIES and retry_delay:
            await asyncio.sleep(retry_delay * (attempt + 1))
    log.error("catch %s FAILED: %s", catch_id, last_err)
    return PhotoAnalyzed(catchId=catch_id, status="FAILED", phash=pre.phash,
                         reason=f"{REASON_FAILED} ({last_err})")


def resolve_path(photo_path: str, photos_dir: str) -> str:
    """Accept absolute paths inside PHOTOS_DIR or paths relative to it; refuse traversal."""
    base = os.path.realpath(photos_dir)
    p = photo_path if os.path.isabs(photo_path) else os.path.join(base, photo_path)
    p = os.path.realpath(p)
    if os.path.commonpath([base, p]) != base:
        raise FileNotFoundError(photo_path)
    return p


def _read(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


async def handle_submitted(msg: PhotoSubmitted, analyzer: Analyzer, settings: Settings,
                           retry_delay: float = 0.5) -> PhotoAnalyzed:
    try:
        path = resolve_path(msg.photoPath, settings.photos_dir)
        data = await asyncio.to_thread(_read, path)
    except (OSError, ValueError):
        return PhotoAnalyzed(catchId=msg.catchId, status="REJECTED", reason=REASON_NOT_FOUND)
    return await analyze_bytes(msg.catchId, data, analyzer, settings, retry_delay)
