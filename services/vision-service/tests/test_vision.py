import asyncio
import io
import json

import numpy as np
import pytest
from PIL import Image
from pydantic import ValidationError

from app.analyzer import MockAnalyzer
from app.config import Settings
from app.kafka_worker import process_record
from app.pipeline import REASON_FAILED, analyze_bytes, handle_submitted
from app.preprocess import REASON_BLUR, REASON_DARK, preprocess
from app.schema import AnalysisResult, PhotoSubmitted


def _jpeg(arr: np.ndarray, exif: bool = False) -> bytes:
    img = Image.fromarray(arr.astype("uint8"))
    buf = io.BytesIO()
    kw = {}
    if exif:
        ex = Image.Exif()
        ex[0x010F] = "SecretCam"  # Make
        kw["exif"] = ex.tobytes()
    img.save(buf, "JPEG", quality=95, **kw)
    return buf.getvalue()


def sharp(w=2000, h=1500):
    rng = np.random.default_rng(0)
    base = np.kron(rng.integers(0, 2, (h // 20, w // 20)) * 200 + 30, np.ones((20, 20)))
    return np.stack([base] * 3, -1)


def flat(v, w=400, h=300):
    return np.full((h, w, 3), v)


def settings(tmp_path=None):
    s = Settings()
    s.photos_dir = str(tmp_path) if tmp_path else "/photos"
    s.kafka_enabled = False
    return s


VALID = {"steps": 4, "kerbRange": ">7", "widthRange": None, "ramp": False, "handrail": True,
         "obstacles": [], "difficulty": 7.4, "confidence": 0.82, "relevant": True}


class FakeAnalyzer:
    name = "fake"

    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = 0

    async def analyze(self, jpeg):
        self.calls += 1
        r = self.responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


class FakeProducer:
    def __init__(self):
        self.sent = []

    async def send_and_wait(self, topic, key=None, value=None):
        self.sent.append((topic, key, value))


run = asyncio.run


# ---------- preprocessing ----------

def test_sharp_image_ok_resized_and_exif_stripped():
    p = preprocess(_jpeg(sharp(), exif=True))
    assert p.ok and p.phash and len(p.phash) == 16
    out = Image.open(io.BytesIO(p.jpeg))
    assert max(out.size) == 1280
    assert not out.getexif()


def test_blurry_rejected():
    p = preprocess(_jpeg(flat(128)))
    assert not p.ok and p.reason == REASON_BLUR


def test_dark_rejected():
    p = preprocess(_jpeg(flat(5)))
    assert not p.ok and p.reason == REASON_DARK


def test_garbage_rejected():
    assert not preprocess(b"not an image").ok


def test_phash_stable():
    a = preprocess(_jpeg(sharp())).phash
    b = preprocess(_jpeg(sharp())).phash
    assert a == b


# ---------- schema ----------

def test_schema_valid():
    r = AnalysisResult.model_validate(VALID)
    assert r.kerbRange == ">7" and r.widthRange is None


@pytest.mark.parametrize("patch", [{"kerbRange": "5"}, {"widthRange": "80"}, {"difficulty": 11},
                                   {"confidence": 1.5}, {"steps": -1}])
def test_schema_invalid(patch):
    with pytest.raises(ValidationError):
        AnalysisResult.model_validate({**VALID, **patch})


# ---------- pipeline ----------

def test_pipeline_ok():
    a = FakeAnalyzer([json.dumps(VALID)])
    out = run(analyze_bytes("c1", _jpeg(sharp()), a, settings(), retry_delay=0))
    assert out.status == "OK" and out.result.steps == 4 and out.phash
    d = json.loads(out.model_dump_json())
    assert set(d) == {"catchId", "status", "result", "phash", "reason", "model"}
    assert d["model"] == "fake"
    assert "relevant" not in d["result"]


def test_pipeline_retry_then_ok():
    a = FakeAnalyzer([RuntimeError("503"), "{bad json", json.dumps(VALID)])
    out = run(analyze_bytes("c1", _jpeg(sharp()), a, settings(), retry_delay=0))
    assert out.status == "OK" and a.calls == 3


def test_pipeline_failed_after_retries():
    a = FakeAnalyzer([RuntimeError("x")] * 2)
    out = run(analyze_bytes("c1", _jpeg(sharp()), a, settings(), retry_delay=0))
    assert out.status == "FAILED" and out.reason == REASON_FAILED and a.calls == 2


def test_pipeline_irrelevant_rejected():
    a = FakeAnalyzer([json.dumps({**VALID, "relevant": False, "rejectReason": "Selfie"})])
    out = run(analyze_bytes("c1", _jpeg(sharp()), a, settings(), retry_delay=0))
    assert out.status == "REJECTED" and out.reason == "Selfie" and out.result is None


def test_blurry_skips_ai():
    a = FakeAnalyzer([])
    out = run(analyze_bytes("c1", _jpeg(flat(128)), a, settings(), retry_delay=0))
    assert out.status == "REJECTED" and a.calls == 0


def test_mock_analyzer_deterministic():
    img = _jpeg(sharp())
    o1 = run(analyze_bytes("c", img, MockAnalyzer(), settings(), retry_delay=0))
    o2 = run(analyze_bytes("c", img, MockAnalyzer(), settings(), retry_delay=0))
    assert o1.status == "OK" and o1.result.obstacles == ["MOCK"] and o1 == o2


def test_missing_file_and_traversal(tmp_path):
    s = settings(tmp_path)
    for path in ("nope.jpg", "../../etc/passwd"):
        out = run(handle_submitted(PhotoSubmitted(catchId="c", photoPath=path), MockAnalyzer(), s, 0))
        assert out.status == "REJECTED"


# ---------- kafka message handling ----------

def test_process_record_produces_keyed_message(tmp_path):
    (tmp_path / "2026").mkdir()
    (tmp_path / "2026" / "a.jpg").write_bytes(_jpeg(sharp()))
    s = settings(tmp_path)
    msg = {"catchId": "abc", "photoPath": str(tmp_path / "2026" / "a.jpg"), "lat": 50.06,
           "lng": 19.94, "spawnId": "s", "placeId": None, "submittedAt": "2026-10-03T14:05:00Z"}
    prod = FakeProducer()
    assert run(process_record(json.dumps(msg).encode(), prod, FakeAnalyzer([json.dumps(VALID)]), s, 0))
    topic, key, value = prod.sent[0]
    assert topic == "photo.analyzed" and key == b"abc"
    body = json.loads(value)
    assert body["status"] == "OK" and body["result"]["kerbRange"] == ">7" and body["reason"] is None


def test_process_record_malformed_skipped():
    prod = FakeProducer()
    assert not run(process_record(b"{}", prod, MockAnalyzer(), settings(), 0))
    assert prod.sent == []


# ---------- http ----------

def test_http_health_and_analyze(monkeypatch):
    monkeypatch.setenv("KAFKA_ENABLED", "false")
    monkeypatch.setenv("GEMINI_API_KEY", "")
    from fastapi.testclient import TestClient
    from app.main import app

    with TestClient(app) as c:
        assert c.get("/health").json()["analyzer"] == "mock"
        r = c.post("/analyze", files={"file": ("a.jpg", _jpeg(sharp()), "image/jpeg")})
        assert r.status_code == 200 and r.json()["status"] == "OK"
