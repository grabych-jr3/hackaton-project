# central-api (Java 21 · Spring Boot 3.5 · PostGIS · Kafka)

Central REST API for the Flutter app. Spec: `docs/BACKEND.md`.

## Run with Docker (whole stack)
```bash
cp .env.example .env   # in repo root, fill ORS_API_KEY / JWT_SECRET / GEMINI_API_KEY
docker compose up --build
```
Swagger: http://localhost:8080/swagger-ui.html

## Run locally (without the API container)
```bash
docker compose up db redpanda
cd services/central-api
ORS_API_KEY=... JWT_SECRET=... ./gradlew bootRun     # Windows: gradlew.bat bootRun
```
Defaults: DB `localhost:5432/kbb` (kbb/kbb), Kafka `localhost:19092`, photos in `./photos`.
Tests: `./gradlew test` (unit tests, no Docker needed).

## Env
| Var | Purpose |
|---|---|
| `ORS_API_KEY` | OpenRouteService key; empty -> straight-line fallback (`fallback: true`) |
| `JWT_SECRET` | HS256 secret; empty -> random per start (tokens die on restart) |
| `PHOTOS_DIR` | shared photo volume (`/photos` in Docker) |
| `ADMIN_TOKEN` | enables `POST /api/v1/admin/import` (header `X-Admin-Token`) |
| `CORS_EXTRA_ORIGINS` | comma-separated extra origins (localhost:* always allowed) |
| `SEED_ENABLED` | seed demo places when `place` is empty (default true) |

## Endpoints (`/api/v1`)
- `POST /auth/anonymous` `{deviceId}` -> `{token,userId,points}`
- `GET /places?bbox=minLng,minLat,maxLng,maxLat&category=` (public), `GET /places/{id}` (public)
- `POST /places/{id}/facts`, `POST /facts/{id}/confirm`, `POST /facts/{id}/dispute` (JWT)
- `POST /routes` (JWT) - ORS wheelchair proxy, 10 min cache
- `POST /catches` multipart (`photo, lat, lng, takenAt, spawnId?, placeId?`) -> 202; `GET /catches/{id}` (JWT)
- `GET /health/sources`
- `POST /admin/import` - Overpass import (also cron 04:00)

Kafka: produces `photo.submitted`, consumes `photo.analyzed` (idempotent, DLQ `photo.analyzed.dlq` after 3 tries).
