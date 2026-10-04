# vision-service (Python 3.12 · FastAPI · OpenCV · Gemini)

AI analysis of barrier photos (`docs/TZ.md` 4.4, `docs/BACKEND.md` 6).

Flow: consume `photo.submitted` → read file from shared volume (`PHOTOS_DIR`) → preprocess →
Gemini (structured output) → produce `photo.analyzed` keyed by `catchId`.

Preprocessing (`app/preprocess.py`):
- darkness (mean luminance) and blur (variance of Laplacian) checks → `REJECTED` with a Polish reason;
- resize to max 1280 px, EXIF stripped (orientation applied first);
- perceptual hash → `phash` in the output (duplicate detection is central-api's job);
- best-effort face blur (OpenCV Haar cascade).

AI (`app/analyzer.py`): `google-genai`, `response_schema` with ranges (`kerbRange`, `widthRange`).
The model also returns `relevant` — if `false` the photo is `REJECTED`. The answer is validated with pydantic.

### Model rotation (`app/pipeline.py`, `app/rotation.py`)
- Ordered list `GEMINI_MODELS` (default `gemini-3.7-flash,gemini-3.8-flash,gemini-flash-latest,gemini-3.5-flash,gemini-2.5-flash`);
  `GEMINI_MODEL`, if set, goes first.
- 503 / 429 / 500 / `UNAVAILABLE` / `RESOURCE_EXHAUSTED` / `DEADLINE_EXCEEDED` / timeout → immediately the next
  model (0.5–1 s jitter). 404 `NOT_FOUND` (retired model) → skipped for the rest of this photo.
- Invalid JSON → one retry on the same model, then the next model.
- At most 2 passes over the list; each call `asyncio.wait_for` 15 s (`AI_CALL_TIMEOUT_S`); total budget 60 s per
  photo (`AI_TIME_BUDGET_S`).
- In-memory circuit breaker: a model that returned 503/429 is on cooldown for 2 min (`MODEL_COOLDOWN_S`) and is tried
  last for subsequent photos.
- The model that produced the answer is logged and sent as `"model"` in `photo.analyzed`.
- All models fail → `FAILED`, `reason="AI chwilowo niedostępne — spróbuj ponownie za chwilę"`.

### Resilient Kafka consumer (`app/kafka_worker.py`)
- `max_poll_interval_ms=300000`, `session_timeout_ms=30000`, `heartbeat_interval_ms=3000`, `max_poll_records=1`.
- A supervisor recreates consumer+producer after ANY exception (incl. LeaveGroup / stopped consumer) with backoff
  1, 2, 5, 10, 30 s… forever; watchdog recreates the consumer if it has no partition assignment for > 60 s.
- Offsets are committed per record, only after `photo.analyzed` was produced.

**No `GEMINI_API_KEY` → deterministic MOCK analyzer** (`obstacles: ["MOCK"]`, logged loudly).

## Endpoints (port 8000)
- `GET /health` → `{status, analyzer: "gemini"|"mock", kafka, kafkaConnected, assignedPartitions, lastMessageAt,
  consumer: {running, connected, restarts, lastError, ...}, models: {"<model>": {cooldown, remainingS}}}`
- `POST /analyze` (multipart `file`, optional `?catchId=`) → same `photo.analyzed` JSON, synchronously (debug/demo).

## Env
See `.env.example`: `KAFKA_BOOTSTRAP`, `GEMINI_API_KEY`, `GEMINI_MODEL`, `GEMINI_MODELS`,
`AI_TIME_BUDGET_S`, `AI_CALL_TIMEOUT_S`, `MODEL_COOLDOWN_S`, `PHOTOS_DIR`,
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
