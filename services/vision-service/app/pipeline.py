"""Full photo pipeline: preprocess -> AI (model rotation) -> validated photo.analyzed message."""
import asyncio
import logging
import os
import random

from pydantic import ValidationError

from .analyzer import Analyzer
from .config import Settings
from .preprocess import preprocess
from .rotation import COOLDOWN, ModelCooldown, classify_error
from .schema import AnalysisResult, GeminiAnswer, PhotoAnalyzed, PhotoSubmitted

log = logging.getLogger(__name__)

MAX_PASSES = 2    # at most 2 passes over the model list
JSON_RETRIES = 1  # invalid JSON -> one retry on the same model, then the next model
REASON_FAILED = "AI chwilowo niedostępne — spróbuj ponownie za chwilę"
REASON_NOT_FOUND = "Nie znaleziono pliku zdjęcia"
REASON_IRRELEVANT = "Na zdjęciu nie widać bariery ani przejścia — sfotografuj miejsce"


class _InvalidAnswer(Exception):
    pass


async def _call(analyzer: Analyzer, jpeg: bytes, model: str | None, timeout: float) -> GeminiAnswer:
    coro = analyzer.analyze(jpeg) if model is None else analyzer.analyze(jpeg, model=model)
    raw = await asyncio.wait_for(coro, timeout=timeout)
    try:
        return GeminiAnswer.model_validate_json(raw)
    except ValidationError as e:
        raise _InvalidAnswer(f"invalid AI response: {e.error_count()} errors") from e


async def run_ai(catch_id: str, jpeg: bytes, analyzer: Analyzer, settings: Settings,
                 retry_delay: float = 0.5, cooldown: ModelCooldown | None = None
                 ) -> tuple[GeminiAnswer | None, str | None, str]:
    """Try models in rotation order. Returns (answer, model, last_error)."""
    cooldown = cooldown or COOLDOWN
    loop = asyncio.get_running_loop()
    deadline = loop.time() + settings.ai_time_budget
    models: list[str] = list(getattr(analyzer, "models", None) or [])
    retired: set[str] = set()
    last_err = "unknown"
    first_call = True

    for pass_no in range(MAX_PASSES):
        order: list[str | None] = cooldown.order(models) if models else [None]
        for model in order:
            if model in retired:
                continue
            label = model or getattr(analyzer, "name", "?")
            for attempt in range(1 + JSON_RETRIES):
                remaining = deadline - loop.time()
                if remaining <= 0:
                    log.error("catch %s: AI time budget %.0fs exhausted", catch_id, settings.ai_time_budget)
                    return None, None, f"time budget exceeded; last: {last_err}"
                if not first_call and retry_delay:  # small jitter (0.5-1 s by default)
                    await asyncio.sleep(min(retry_delay * (1 + random.random()), remaining))
                    remaining = deadline - loop.time()
                    if remaining <= 0:
                        return None, None, f"time budget exceeded; last: {last_err}"
                first_call = False
                try:
                    ans = await _call(analyzer, jpeg, model, min(settings.ai_call_timeout, remaining))
                    log.info("catch %s: result from model %s (pass %d)", catch_id, label, pass_no + 1)
                    return ans, label, ""
                except _InvalidAnswer as e:
                    last_err = f"{label}: {e}"
                    log.warning("catch %s: %s (attempt %d)", catch_id, last_err, attempt + 1)
                    continue
                except asyncio.TimeoutError:
                    last_err = f"{label}: timeout"
                    log.warning("catch %s: %s", catch_id, last_err)
                    break
                except Exception as e:
                    kind = classify_error(e)
                    last_err = f"{label}: {type(e).__name__} {str(e)[:120]}"
                    log.warning("catch %s: model %s failed (%s): %s", catch_id, label, kind, e)
                    if kind == "overloaded" and model is not None:
                        cooldown.mark(model)
                    elif kind == "not_found" and model is not None:
                        retired.add(model)
                    break
    return None, None, last_err


async def analyze_bytes(catch_id: str, data: bytes, analyzer: Analyzer, settings: Settings,
                        retry_delay: float = 0.5, cooldown: ModelCooldown | None = None) -> PhotoAnalyzed:
    pre = await asyncio.to_thread(
        preprocess, data, max_side=settings.max_side,
        blur_threshold=settings.blur_threshold, dark_threshold=settings.dark_threshold,
    )
    if not pre.ok:
        return PhotoAnalyzed(catchId=catch_id, status="REJECTED", phash=pre.phash, reason=pre.reason)

    ans, model, last_err = await run_ai(catch_id, pre.jpeg, analyzer, settings, retry_delay, cooldown)
    if ans is None:
        log.error("catch %s FAILED (all models): %s", catch_id, last_err)
        return PhotoAnalyzed(catchId=catch_id, status="FAILED", phash=pre.phash, reason=REASON_FAILED)
    if not ans.relevant:
        return PhotoAnalyzed(catchId=catch_id, status="REJECTED", phash=pre.phash,
                             reason=ans.rejectReason or REASON_IRRELEVANT, model=model)
    result = AnalysisResult.model_validate(ans.model_dump(exclude={"relevant", "rejectReason"}))
    return PhotoAnalyzed(catchId=catch_id, status="OK", result=result, phash=pre.phash, model=model)


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
