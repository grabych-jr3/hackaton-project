import os
from dataclasses import dataclass, field


def _bool(v: str | None, default: bool) -> bool:
    if v is None or v == "":
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")


@dataclass
class Settings:
    kafka_bootstrap: str = field(default_factory=lambda: os.getenv("KAFKA_BOOTSTRAP", "localhost:19092"))
    kafka_enabled: bool = field(default_factory=lambda: _bool(os.getenv("KAFKA_ENABLED"), True))
    kafka_group_id: str = field(default_factory=lambda: os.getenv("KAFKA_GROUP_ID", "vision-service"))
    topic_in: str = "photo.submitted"
    topic_out: str = "photo.analyzed"
    gemini_api_key: str = field(default_factory=lambda: os.getenv("GEMINI_API_KEY", "").strip())
    gemini_model: str = field(default_factory=lambda: os.getenv("GEMINI_MODEL", "gemini-2.5-flash"))
    photos_dir: str = field(default_factory=lambda: os.getenv("PHOTOS_DIR", "/photos"))
    blur_threshold: float = field(default_factory=lambda: float(os.getenv("BLUR_THRESHOLD", "60")))
    dark_threshold: float = field(default_factory=lambda: float(os.getenv("DARK_THRESHOLD", "40")))
    max_side: int = field(default_factory=lambda: int(os.getenv("MAX_SIDE", "1280")))


def get_settings() -> Settings:
    return Settings()
