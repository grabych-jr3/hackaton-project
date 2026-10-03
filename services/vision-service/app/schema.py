from typing import Literal, Optional

from pydantic import BaseModel, Field

KerbRange = Literal["0-3", "3-7", ">7"]
WidthRange = Literal["<70", "70-90", ">90"]
Status = Literal["OK", "REJECTED", "FAILED"]


class AnalysisResult(BaseModel):
    """Contract from docs/BACKEND.md 6.2 / TZ 4.4 (ranges, not exact cm)."""

    steps: Optional[int] = Field(default=None, ge=0, le=200)
    kerbRange: Optional[KerbRange] = None
    widthRange: Optional[WidthRange] = None
    ramp: Optional[bool] = None
    handrail: Optional[bool] = None
    obstacles: list[str] = Field(default_factory=list)
    difficulty: float = Field(ge=0, le=10)
    confidence: float = Field(ge=0, le=1)


class GeminiAnswer(AnalysisResult):
    """What the model returns: the result plus a relevance flag used to REJECT."""

    relevant: bool = True
    rejectReason: Optional[str] = None


class PhotoSubmitted(BaseModel):
    catchId: str
    photoPath: str
    lat: Optional[float] = None
    lng: Optional[float] = None
    spawnId: Optional[str] = None
    placeId: Optional[str] = None
    submittedAt: Optional[str] = None


class PhotoAnalyzed(BaseModel):
    catchId: str
    status: Status
    result: Optional[AnalysisResult] = None
    phash: Optional[str] = None
    reason: Optional[str] = None
