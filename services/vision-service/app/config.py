import os
from dataclasses import dataclass, field

DEFAULT_MODELS = "gemini-3.7-flash,gemini-3.8-flash,gemini-flash-latest,gemini-3.5-flash,gemini-2.5-flash"


def _bool(v: str | None, default: bool) -> bool:
    if v is None or v == "":
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")


def parse_models(gemini_model: str | None, gemini_models: str | None) -> list[str]:
    """Ordered, de-duplicated model list: GEMINI_MODEL (if set) first, then GEMINI_MODELS."""
    raw = (gemini_models or "").strip() or DEFAULT_MODELS
    first = (gemini_model or "").strip()
    out: list[str] = []
    for m in ([first] if first else []) + [x.strip() for x in raw.split(",")]:
        if m and m not in out:
            out.append(m)
    return out


@dataclass
class Settings:
    kafka_bootstrap: str = field(default_factory=lambda: os.getenv("KAFKA_BOOTSTRAP", "localhost:19092"))
    kafka_enabled: bool = field(default_factory=lambda: _bool(os.getenv("KAFKA_ENABLED"), True))
    kafka_group_id: str = field(default_factory=lambda: os.getenv("KAFKA_GROUP_ID", "vision-service"))
    topic_in: str = "photo.submitted"
    topic_out: str = "photo.analyzed"
    gemini_api_key: str = field(default_factory=lambda: os.getenv("GEMINI_API_KEY", "").strip())
    gemini_models: list[str] = field(
        default_factory=lambda: parse_models(os.getenv("GEMINI_MODEL"), os.getenv("GEMINI_MODELS")))
    ai_time_budget: float = field(default_factory=lambda: float(os.getenv("AI_TIME_BUDGET_S", "60")))
    ai_call_timeout: float = field(default_factory=lambda: float(os.getenv("AI_CALL_TIMEOUT_S", "15")))
    model_cooldown: float = field(default_factory=lambda: float(os.getenv("MODEL_COOLDOWN_S", "120")))
    photos_dir: str = field(default_factory=lambda: os.getenv("PHOTOS_DIR", "/photos"))
    blur_threshold: float = field(default_factory=lambda: float(os.getenv("BLUR_THRESHOLD", "60")))
    dark_threshold: float = field(default_factory=lambda: float(os.getenv("DARK_THRESHOLD", "40")))
    max_side: int = field(default_factory=lambda: int(os.getenv("MAX_SIDE", "1280")))

    @property
    def gemini_model(self) -> str:
        """Primary model (kept for backward compatibility)."""
        return self.gemini_models[0]


def get_settings() -> Settings:
    return Settings()
