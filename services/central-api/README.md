# central-api (Java 21 · Spring Boot 3.5 · PostGIS · Kafka)

Central REST API for the Flutter app. Spec: `docs/BACKEND.md`.

## Run with Docker (whole stack)
```bash
cp .env.example .env   # in repo root, fill ORS_API_KEY / JWT_SECRET / GEMINI_API_KEY
docker compose up -d --build
docker compose ps        # db, redpanda, central-api: healthy; vision-service: running
```
central-api waits for healthy db/redpanda; Flyway runs V1 (schema) + V2 (game), then 11 demo places are seeded.
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
- `POST /routes` (public) - ORS wheelchair proxy (language pl), 10 min cache; `segments[].warning` is a nullable string
- `GET /game/catalog` (public), `GET /game/state`, `POST /game/reports`, `POST /game/vouchers` (JWT) - see BACKEND.md 5.7a
- `POST /catches` multipart (`photo, lat, lng, takenAt, spawnId?, placeId?`) -> 202; `GET /catches/{id}` (JWT)
- `GET /health` (also `/health` without prefix) -> `{status:"UP"}`, `GET /health/sources`
- `POST /admin/import` - Overpass import (also cron 04:00)

Kafka: produces `photo.submitted`, consumes `photo.analyzed` (idempotent, DLQ `photo.analyzed.dlq` after 3 tries).

Errors: `{"error": CODE, "code": CODE, "message": ...}`; missing/invalid token -> 401.

## Smoke test (curl)
```bash
A=http://localhost:8080/api/v1
curl -s localhost:8080/health                                   # {"status":"UP"}
T=$(curl -s -X POST $A/auth/anonymous -H 'Content-Type: application/json' -d '{"deviceId":"dev-1"}'     | sed -E 's/.*"token":"([^"]+)".*//')                     # new user: points 120
curl -s $A/places | head -c 300                                 # 11 demo places
curl -s $A/places/wawel
curl -s -X POST $A/routes -H 'Content-Type: application/json'   -d '{"points":[{"lat":50.0617,"lng":19.9373},{"lat":50.0541,"lng":19.9354}],"profile":{"maxKerbCm":3,"minWidthCm":80,"maxInclinePct":6}}'
curl -s $A/game/catalog
curl -s -H "Authorization: Bearer $T" $A/game/state
curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' $A/game/reports   -d '{"placeId":"wawel","report":{"placeId":"wawel","steps":3,"curb":"high","passage":"narrow","noRamp":true,"uneven":false,"obstacles":false}}'
curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' $A/game/vouchers -d '{"offerId":"lody-huta"}'
curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' $A/game/vouchers -d '{"offerId":"bar-schody"}'  # 403
curl -s -X POST -H "Authorization: Bearer $T" $A/facts/<factId>/confirm                                                     # 2nd time: 409
```
