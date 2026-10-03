"""AI analyzers: Gemini (google-genai, structured output) and a deterministic mock."""
import hashlib
import logging
from typing import Protocol

from .schema import GeminiAnswer

log = logging.getLogger(__name__)

SYSTEM_PROMPT = """Jesteś audytorem dostępności przestrzeni miejskiej (Kraków) dla osób na wózkach \
inwalidzkich i rodziców z wózkami dziecięcymi. Analizujesz JEDNO zdjęcie miejsca (wejście, chodnik, \
przejście, schody, krawężnik, drzwi, rampa).

Zwróć WYŁĄCZNIE JSON zgodny ze schematem:
- steps: liczba widocznych stopni (0 jeśli wyraźnie brak stopni), null jeśli nie widać.
- kerbRange: wysokość krawężnika jako przedział cm: "0-3", "3-7", ">7"; null jeśli nie widać krawężnika.
- widthRange: szerokość przejścia/drzwi: "<70", "70-90", ">90" cm; null jeśli nie da się ocenić.
- ramp: czy widoczna jest rampa/podjazd; null jeśli nie wiadomo.
- handrail: czy widoczna jest poręcz; null jeśli nie wiadomo.
- obstacles: krótkie nazwy przeszkód (np. "słupek", "kostka brukowa", "zaparkowany samochód"); [] jeśli brak.
- difficulty: 0 (w pełni dostępne) – 10 (nieprzejezdne dla wózka).
- confidence: 0–1, uczciwa pewność oceny całości.
- relevant: false, jeśli na zdjęciu nie ma sceny istotnej dla dostępności (np. selfie, jedzenie, niebo).
- rejectReason: krótki powód po polsku, gdy relevant=false.

Zasady: nie mierzysz centymetrów, tylko przedziały. Jeśli czegoś nie widać — null, NIE zgaduj i \
NIE wymyślaj. Pewność oceniaj uczciwie; przy słabej widoczności obniż confidence."""

RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "steps": {"type": "INTEGER", "nullable": True},
        "kerbRange": {"type": "STRING", "enum": ["0-3", "3-7", ">7"], "nullable": True},
        "widthRange": {"type": "STRING", "enum": ["<70", "70-90", ">90"], "nullable": True},
        "ramp": {"type": "BOOLEAN", "nullable": True},
        "handrail": {"type": "BOOLEAN", "nullable": True},
        "obstacles": {"type": "ARRAY", "items": {"type": "STRING"}},
        "difficulty": {"type": "NUMBER"},
        "confidence": {"type": "NUMBER"},
        "relevant": {"type": "BOOLEAN"},
        "rejectReason": {"type": "STRING", "nullable": True},
    },
    "required": ["steps", "kerbRange", "widthRange", "ramp", "handrail", "obstacles",
                 "difficulty", "confidence", "relevant"],
}


class Analyzer(Protocol):
    name: str

    async def analyze(self, jpeg: bytes) -> str:
        """Return raw JSON text (validated by the pipeline)."""
        ...


class MockAnalyzer:
    name = "mock"

    async def analyze(self, jpeg: bytes) -> str:
        h = hashlib.sha256(jpeg).digest()
        ans = GeminiAnswer(
            steps=h[0] % 5,
            kerbRange=["0-3", "3-7", ">7"][h[1] % 3],
            widthRange=["<70", "70-90", ">90"][h[2] % 3],
            ramp=bool(h[3] % 2),
            handrail=bool(h[4] % 2),
            obstacles=["MOCK"],
            difficulty=round(h[5] / 255 * 10, 1),
            confidence=0.5,
        )
        return ans.model_dump_json()


class GeminiAnalyzer:
    name = "gemini"

    def __init__(self, api_key: str, model: str):
        from google import genai

        self._client = genai.Client(api_key=api_key)
        self._model = model

    async def analyze(self, jpeg: bytes) -> str:
        from google.genai import types

        resp = await self._client.aio.models.generate_content(
            model=self._model,
            contents=[
                types.Part.from_bytes(data=jpeg, mime_type="image/jpeg"),
                "Oceń dostępność miejsca na zdjęciu.",
            ],
            config=types.GenerateContentConfig(
                system_instruction=SYSTEM_PROMPT,
                response_mime_type="application/json",
                response_schema=RESPONSE_SCHEMA,
                temperature=0.1,
            ),
        )
        return resp.text or ""


def build_analyzer(api_key: str, model: str) -> Analyzer:
    if not api_key:
        log.warning("=" * 60)
        log.warning("GEMINI_API_KEY not set -> using deterministic MOCK analyzer (obstacles=['MOCK'])")
        log.warning("=" * 60)
        return MockAnalyzer()
    log.info("Using Gemini analyzer, model=%s", model)
    return GeminiAnalyzer(api_key, model)
