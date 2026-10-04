"""Gemini model rotation helpers: error classification + in-memory per-model cooldown."""
import time
from typing import Callable

# Errors after which the model is put on cooldown (overloaded / quota).
COOLDOWN_MARKERS = ("503", "429", "UNAVAILABLE", "RESOURCE_EXHAUSTED", "HIGH DEMAND", "OVERLOADED")


def classify_error(e: BaseException) -> str:
    """Return 'overloaded' (cooldown + next model), 'not_found' (model retired) or 'error'."""
    code = getattr(e, "code", None)
    status = str(getattr(e, "status", "") or "")
    text = f"{code} {status} {e}".upper()
    if code in (503, 429) or any(m in text for m in COOLDOWN_MARKERS):
        return "overloaded"
    if code == 404 or "NOT_FOUND" in text or "404" in text:
        return "not_found"
    return "error"  # 500 / INTERNAL / DEADLINE_EXCEEDED / timeout / network ... -> next model


class ModelCooldown:
    """Remembers models that recently returned 503/429 so the next photos try them last."""

    def __init__(self, seconds: float = 120.0, clock: Callable[[], float] = time.monotonic):
        self.seconds = seconds
        self.clock = clock
        self._until: dict[str, float] = {}

    def mark(self, model: str) -> None:
        self._until[model] = self.clock() + self.seconds

    def is_cooling(self, model: str) -> bool:
        until = self._until.get(model)
        if until is None:
            return False
        if until <= self.clock():
            self._until.pop(model, None)
            return False
        return True

    def order(self, models: list[str]) -> list[str]:
        """Healthy models first (original order), cooling models at the end as a last resort."""
        return [m for m in models if not self.is_cooling(m)] + [m for m in models if self.is_cooling(m)]

    def status(self, models: list[str]) -> dict[str, dict]:
        now = self.clock()
        out = {}
        for m in models:
            cooling = self.is_cooling(m)
            out[m] = {"cooldown": cooling,
                      "remainingS": round(self._until[m] - now, 1) if cooling else 0}
        return out

    def clear(self) -> None:
        self._until.clear()


COOLDOWN = ModelCooldown()
