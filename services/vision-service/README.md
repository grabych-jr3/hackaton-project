# vision-service (Python 3.12 · FastAPI · OpenCV · Gemini)

AI analysis of barrier photos (`docs/TZ.md` 4.4, `docs/BACKEND.md` 6).

Flow: consume `photo.submitted` → read file from shared volume (`PHOTOS_DIR`) → preprocess →
Gemini (structured output) → produce `photo.analyzed` keyed by `catchId`.

Preprocessing (`app/preprocess.py`):
- darkness (mean luminance) and blur (variance of Laplacian) checks → `REJECTED` with a Polish reason;
- resize to max 1280 px, EXIF stripped (orientation applied first);
- perceptual hash → `phash` in the output (duplicate detection is central-api's job);
- best-effort face blur (OpenCV Haar cascade).

AI (`app/analyzer.py`): `google-genai`, model `GEMINI_MODEL` (default `gemini-3.7-flash`),
`response_schema` with ranges (`kerbRange`, `widthRange`). The model also returns `relevant` —
if `false` the photo is `REJECTED`. The answer is validated with pydantic; on errors / invalid JSON
it retries up to 2 times, then `FAILED` with `reason="AI niedostępne, użyj ankiety (...)"`.

**No `GEMINI_API_KEY` → deterministic MOCK analyzer** (`obstacles: ["MOCK"]`, logged loudly).

## Endpoints (port 8000)
- `GET /health` → `{status, analyzer: "gemini"|"mock", kafka}`
- `POST /analyze` (multipart `file`, optional `?catchId=`) → same `photo.analyzed` JSON, synchronously (debug/demo).

## Env
See `.env.example`: `KAFKA_BOOTSTRAP`, `GEMINI_API_KEY`, `GEMINI_MODEL`, `PHOTOS_DIR`,
`KAFKA_ENABLED` (set `false` to run HTTP only), `KAFKA_GROUP_ID`, `BLUR_THRESHOLD`, `DARK_THRESHOLD`, `MAX_SIDE`.

## Run
```bash
python -m venv .venv && .venv/Scripts/pip install -r requirements-dev.txt   # Linux: .venv/bin
KAFKA_ENABLED=false .venv/Scripts/uvicorn app.main:app --port 8000
curl -F file=@photo.jpg localhost:8000/analyze
.venv/Scripts/python -m pytest -q
```
Docker: `docker build -t vision-service .` (compose service from `docs/BACKEND.md` §3).

`photoPath` must be inside `PHOTOS_DIR` (absolute or relative); missing file → `REJECTED`.
Offsets are committed after the result is produced (at-least-once; central-api is idempotent).
