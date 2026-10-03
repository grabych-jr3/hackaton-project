"""Image quality checks and sanitisation before the AI call."""
import io
import logging
from dataclasses import dataclass
from typing import Optional

import cv2
import imagehash
import numpy as np
from PIL import Image, ImageOps

log = logging.getLogger(__name__)

REASON_BLUR = "Zdjęcie jest nieostre — zrób ponownie"
REASON_DARK = "Zdjęcie jest zbyt ciemne — zrób ponownie"
REASON_UNREADABLE = "Nie można odczytać zdjęcia — zrób ponownie"

_face_cascade = None


@dataclass
class Preprocessed:
    ok: bool
    reason: Optional[str] = None
    jpeg: Optional[bytes] = None  # sanitised: resized, no EXIF, faces blurred
    phash: Optional[str] = None
    blur_score: float = 0.0
    brightness: float = 0.0
    faces: int = 0


def blur_score(gray: np.ndarray) -> float:
    """Variance of Laplacian: low = blurry."""
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def brightness(gray: np.ndarray) -> float:
    return float(gray.mean())


def _cascade():
    global _face_cascade
    if _face_cascade is None:
        try:
            c = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
            _face_cascade = c if not c.empty() else False
        except Exception:  # pragma: no cover
            _face_cascade = False
    return _face_cascade or None


def blur_faces(bgr: np.ndarray) -> tuple[np.ndarray, int]:
    """Best-effort face anonymisation. Never raises."""
    try:
        c = _cascade()
        if c is None:
            return bgr, 0
        gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
        faces = c.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5, minSize=(24, 24))
        for (x, y, w, h) in faces:
            k = max(15, (w // 3) | 1)
            bgr[y:y + h, x:x + w] = cv2.GaussianBlur(bgr[y:y + h, x:x + w], (k, k), 0)
        return bgr, len(faces)
    except Exception as e:  # pragma: no cover
        log.warning("face blur failed: %s", e)
        return bgr, 0


def preprocess(data: bytes, *, max_side: int = 1280, blur_threshold: float = 60.0,
               dark_threshold: float = 40.0) -> Preprocessed:
    try:
        img = Image.open(io.BytesIO(data))
        img = ImageOps.exif_transpose(img)  # honour orientation; EXIF dropped below
        img = img.convert("RGB")
    except Exception:
        return Preprocessed(ok=False, reason=REASON_UNREADABLE)

    img.thumbnail((max_side, max_side), Image.LANCZOS)
    clean = Image.frombytes("RGB", img.size, img.tobytes())  # pixels only, no metadata
    phash = str(imagehash.phash(clean))

    bgr = cv2.cvtColor(np.asarray(clean), cv2.COLOR_RGB2BGR)
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    b, lum = blur_score(gray), brightness(gray)
    if lum < dark_threshold:
        return Preprocessed(ok=False, reason=REASON_DARK, phash=phash, blur_score=b, brightness=lum)
    if b < blur_threshold:
        return Preprocessed(ok=False, reason=REASON_BLUR, phash=phash, blur_score=b, brightness=lum)

    bgr, n = blur_faces(bgr)
    ok, buf = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, 85])
    if not ok:  # pragma: no cover
        return Preprocessed(ok=False, reason=REASON_UNREADABLE)
    return Preprocessed(ok=True, jpeg=buf.tobytes(), phash=phash, blur_score=b, brightness=lum, faces=n)
