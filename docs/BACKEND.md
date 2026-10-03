# central-api: план для Java-разработчика

Документ описывает, что нужно сделать в `services/central-api`. Он самодостаточен, но за контекстом можно заглядывать в `docs/TZ.md` (разделы 5–9).
JSON-контракты ниже **совпадают с моделями во Flutter** (`mobile/lib/data/models/`). Если меняете поле, предупредите фронтенд.

---

## 1. Что делает сервис

```
Flutter ──REST /api/v1──► central-api ──Kafka: photo.submitted──► vision-service (Python)
                              │   ▲                                      │
                              │   └────────── Kafka: photo.analyzed ◄────┘
                              ├──► PostgreSQL 16 + PostGIS
                              ├──► OpenRouteService (маршруты, ключ только на сервере)
                              └──► Overpass API (импорт OSM по расписанию)
```

central-api — единственная точка входа для мобильного приложения. Его задачи:
1. Хранить **места** и **факты доступности** с источником, датой и счётчиками подтверждений.
2. Принимать отчёты пользователей (новый факт, подтверждение, спор).
3. Проксировать построение маршрута в OpenRouteService.
4. Считать загруженность квадратов сетки (толпы).
5. Игра: спавн существ, приём фото (через Kafka → vision), очки, ваучеры.

**Важно для приватности:** профиль потребностей пользователя (пороги ступеней, бордюров и т. д.) **не хранится на сервере**. Оценка «Pasuje / Nie pasuje» считается во Flutter. Сервер получает пороги только в запросе маршрута и нигде их не сохраняет.

---

## 2. Стек

| Что | Чем |
|---|---|
| Язык | Java 21 |
| Фреймворк | Spring Boot 3.3+ (Web, Data JPA, Validation, Security, Kafka) |
| Геоданные | Hibernate Spatial + JTS (`org.locationtech.jts.geom.Point`), SRID **4326** |
| Миграции | Flyway (`src/main/resources/db/migration/V1__init.sql`, …) |
| Брокер | Redpanda (Kafka API), Spring Kafka |
| HTTP-клиенты | `RestClient` (Spring 6) для ORS и Overpass |
| Документация API | springdoc-openapi → `/swagger-ui.html` |
| Сборка | Gradle (Kotlin DSL) или Maven, на ваш выбор |
| Запуск | `docker-compose.yml` в корне репозитория |

### Структура пакетов
```
pl.krakowbezbarier.api
├─ config/          SecurityConfig, CorsConfig, KafkaConfig, OrsProperties
├─ auth/            AnonymousAuthController, JwtService
├─ place/           Place, AccessibilityFact, FactVote, PlaceController, PlaceService, repositories
├─ ingest/          SourceAdapter (interface), OverpassAdapter, ImportJob (@Scheduled), SourceStatus
├─ route/           RouteController, OrsClient, RouteRequest/Response
├─ crowd/           GridCell, CrowdReport, CrowdService (@Scheduled), CrowdController
├─ game/            CreatureSpawn, CatchRecord, Bait, PointsLedger, CatchController, SpawnService
│  └─ kafka/        PhotoSubmittedProducer, PhotoAnalyzedListener, events (records)
├─ reward/          Partner, VoucherOffer, Voucher, RewardController
└─ common/          ApiError, GlobalExceptionHandler, GeoUtils
```

---

## 3. docker-compose (корень репозитория)

```yaml
services:
  db:
    image: postgis/postgis:16-3.4
    environment: { POSTGRES_DB: kbb, POSTGRES_USER: kbb, POSTGRES_PASSWORD: kbb }
    ports: ["5432:5432"]
    volumes: [dbdata:/var/lib/postgresql/data]

  redpanda:
    image: redpandadata/redpanda:latest
    command: >
      redpanda start --mode dev-container --smp 1 --memory 512M
      --kafka-addr internal://0.0.0.0:9092,external://0.0.0.0:19092
      --advertise-kafka-addr internal://redpanda:9092,external://localhost:19092
    ports: ["19092:19092"]

  central-api:
    build: ./services/central-api
    environment:
      SPRING_DATASOURCE_URL: jdbc:postgresql://db:5432/kbb
      SPRING_DATASOURCE_USERNAME: kbb
      SPRING_DATASOURCE_PASSWORD: kbb
      SPRING_KAFKA_BOOTSTRAP_SERVERS: redpanda:9092
      ORS_API_KEY: ${ORS_API_KEY}
      JWT_SECRET: ${JWT_SECRET}
      PHOTOS_DIR: /photos
    ports: ["8080:8080"]
    volumes: [photos:/photos]
    depends_on: [db, redpanda]

  vision-service:
    build: ./services/vision-service
    environment:
      KAFKA_BOOTSTRAP: redpanda:9092
      GEMINI_API_KEY: ${GEMINI_API_KEY}
      PHOTOS_DIR: /photos
    volumes: [photos:/photos]
    depends_on: [redpanda]

volumes: { dbdata: {}, photos: {} }
```
Секреты лежат в `.env` в корне (файл в `.gitignore`). При локальной разработке без Docker приложение подключается к `localhost:5432` и `localhost:19092`.

---

## 4. Сущности БД

Общие правила:
- Все геометрии хранятся в `geometry(..., 4326)` и имеют GIST-индекс.
- Расстояния считаются через `ST_DWithin(geom::geography, …, метры)`, иначе получатся градусы.
- Время хранится как `timestamptz`, в Java — `Instant` (или `OffsetDateTime`).
- Enum-поля хранятся в `varchar` (`@Enumerated(EnumType.STRING)`). Значения пишутся **в том же виде, что во Flutter** (camelCase, см. ниже).

### 4.1 Справочник enum (как в JSON)
| Enum | Значения |
|---|---|
| `Feature` | `steps`, `kerbHeight`, `doorWidth`, `incline`, `ramp`, `elevator`, `toilet`, `bench`, `disabledParking` |
| `DataSource` | `osm`, `msip`, `otwarteDane`, `owner`, `user`, `ai`, `estimate` |
| `PlaceCategory` | `attraction`, `museum`, `church`, `cafe`, `restaurant`, `park`, `bridge` |
| `CatchStatus` | `PENDING`, `OK`, `REJECTED`, `FAILED` |
| `Rarity` | `common`, `rare`, `epic`, `legendary` |

### 4.2 Таблицы (MVP — жирным)

**`city`** — города (масштабирование = новая строка)
| поле | тип | комментарий |
|---|---|---|
| id | varchar PK | `krakow` |
| name | varchar | |
| bbox | geometry(Polygon,4326) | область импорта |
| timezone | varchar | `Europe/Warsaw` |
| grid_size_m | int | 250 |

**`place`** — место
| поле | тип | комментарий |
|---|---|---|
| **id** | varchar PK | стабильный ID: `osm:node:123456` / `osm:way:987` или slug для ручных |
| city_id | varchar FK → city | |
| **name** | varchar not null | |
| **category** | varchar | `PlaceCategory` |
| **geom** | geometry(Point,4326) | GIST-индекс |
| address | varchar null | |
| osm_tags | jsonb null | сырые теги OSM (для отладки и повторного маппинга) |
| is_demo | boolean default false | демо-данные помечаются в UI |
| updated_at | timestamptz | |

**`accessibility_fact`** — один факт о доступности
| поле | тип | комментарий |
|---|---|---|
| **id** | uuid PK | |
| **place_id** | varchar FK → place | |
| **feature** | varchar | `Feature` |
| **value** | jsonb | число (`2`), boolean (`true`) или строка-диапазон (`"3-7"`, `">7"`, `"<70"`) |
| **source** | varchar | `DataSource` |
| source_ref | varchar null | `osm:node:123`, `catch:<uuid>`, URL набора данных |
| **fetched_at** | timestamptz | когда получено |
| confirmed_at | timestamptz null | последнее подтверждение |
| **confirmations** | int default 0 | |
| **disputes** | int default 0 | |
| created_by | uuid null FK → app_user | для отчётов пользователей |
| active | boolean default true | скрыть при ≥3 жалобах на модерацию |

Индекс: `(place_id, feature)`. При реимпорте OSM факт с тем же `(place_id, feature, source='osm')` **обновляется**, а не дублируется.

**`fact_vote`** — защита от повторного голосования
| поле | тип |
|---|---|
| fact_id | uuid FK |
| user_id | uuid FK |
| vote | varchar (`confirm` / `dispute`) |
| created_at | timestamptz |
PK `(fact_id, user_id)`.

**`app_user`** — анонимный пользователь (без email и данных о здоровье)
| поле | тип | комментарий |
|---|---|---|
| **id** | uuid PK | |
| **device_hash** | varchar unique | SHA-256 от deviceId, сам deviceId не хранится |
| **points** | int default 0 | текущий баланс |
| created_at | timestamptz | |

**`points_ledger`** — история начислений (источник правды для очков)
| поле | тип | комментарий |
|---|---|---|
| id | uuid PK | |
| user_id | uuid FK | |
| delta | int | +25, −50 … |
| reason | varchar | `catch`, `crowd_report`, `confirm`, `voucher`, `bait` |
| ref_id | varchar | id улова / ваучера |
| created_at | timestamptz | |
Уникальный индекс `(reason, ref_id)` нужен для идемпотентности: повторное Kafka-событие не начислит очки второй раз.

**`grid_cell`** — квадрат сетки 250×250 м
| поле | тип | комментарий |
|---|---|---|
| id | varchar PK | `krakow:x:y` (индексы по сетке) |
| city_id | varchar FK | |
| geom | geometry(Polygon,4326) | |
| poi_weight | double | сумма весов POI (база для толпы) |
| difficulty | double 0..1 | трудность для колясок (из OSM) |
| explored_count | int | число уловов в квадрате |

**`crowd_report`** — ответ «Jak tłoczno?»
| поле | тип |
|---|---|
| id | uuid PK |
| cell_id | varchar FK |
| user_id | uuid FK |
| level | smallint (0 = luźno, 1 = średnio, 2 = tłoczno) |
| created_at | timestamptz |

**`crowd_snapshot`** — посчитанная загруженность (пересчёт каждые 5 мин)
| поле | тип |
|---|---|
| cell_id | varchar FK |
| ts | timestamptz |
| crowd | double 0..1 |
| source_mix | jsonb (`{"base":0.6,"survey":0.3,"live":0.1,"reports":12}`) |
PK `(cell_id, ts)`. Для API нужен только последний снимок.

**`creature_spawn`** — существо на карте
| поле | тип |
|---|---|
| id | uuid PK |
| cell_id | varchar FK |
| geom | geometry(Point,4326) |
| species | varchar (`smok`, `sowa`, `lis`…) |
| rarity | varchar (`Rarity`) |
| expires_at | timestamptz |
| bait_id | uuid null FK |

**`catch_record`** — улов (фото барьера; `catch` — зарезервированное слово в Java)
| поле | тип | комментарий |
|---|---|---|
| id | uuid PK | |
| user_id | uuid FK | |
| spawn_id | uuid FK null | |
| place_id | varchar FK null | если фото у конкретного места |
| geom | geometry(Point,4326) | откуда снято |
| photo_path | varchar | путь в общем томе `/photos` |
| status | varchar | `CatchStatus` |
| ai_result | jsonb null | ответ vision (см. 6.2) |
| ai_confidence | double null | |
| phash | varchar null | от vision, для поиска дубликатов |
| points | int null | сколько начислено |
| created_at / analyzed_at | timestamptz | |

**`bait`** — приманка (P1)
| id uuid PK | user_id uuid | geom Point | expires_at timestamptz |

**`partner`**, **`voucher_offer`**, **`voucher`** — ваучеры (P1)
```
partner(id uuid, place_id varchar FK, name, verified_access boolean)
voucher_offer(id uuid, partner_id FK, title, discount_text, cost_points int, base_quota int, valid_minutes int default 120)
voucher(id uuid, offer_id FK, user_id FK, code varchar, activated_at, expires_at, redeemed_at null)
```

**`source_status`** — состояние внешних источников (для баннера «źródło niedostępne»)
| source varchar PK | last_success_at | last_error_at | last_error varchar | stale boolean |

---

## 5. API: что присылает фронтенд и что получает

Базовый путь `/api/v1`, JSON в UTF-8. Все запросы, кроме `/auth/*` и `/health/*`, идут с заголовком
`Authorization: Bearer <jwt>`. CORS разрешить для `http://localhost:*` и домена веб-сборки.

Формат ошибки (единый для всех эндпоинтов):
```json
{ "error": "NOT_FOUND", "message": "Place osm:node:1 not found" }
```

### 5.1 Анонимная авторизация
`POST /auth/anonymous`
```json
// запрос (Flutter генерирует UUID один раз и хранит на устройстве)
{ "deviceId": "8f1c2a7e-3b4d-4c55-9a10-0e2f7b6d1c99" }
// ответ
{ "token": "eyJ...", "userId": "b3d6...", "points": 0 }
```

### 5.2 Места — **MVP №1**
`GET /places?bbox=19.90,50.04,19.98,50.07&category=museum`
`bbox` = `minLng,minLat,maxLng,maxLat`, параметр `category` необязательный.
```json
{
  "places": [
    {
      "id": "osm:way:123",
      "name": "Sukiennice",
      "category": "museum",
      "lat": 50.0617,
      "lng": 19.9373,
      "address": "Rynek Główny 1/3",
      "isDemo": false,
      "facts": [
        {
          "id": "6a0e…",
          "feature": "steps",
          "value": 0,
          "source": "osm",
          "sourceRef": "osm:way:123",
          "fetchedAt": "2026-08-15T10:00:00Z",
          "confirmedAt": null,
          "confirmations": 0,
          "disputes": 0
        }
      ]
    }
  ],
  "sources": { "osm": { "lastSuccessAt": "2026-10-03T05:00:00Z", "stale": false } }
}
```
Не больше 500 мест на ответ. Факты встраиваются целиком: на одно место их ~5–10.

`GET /places/{id}` — то же, но одно место (`404`, если не найдено).

### 5.3 Отчёт пользователя о факте
`POST /places/{id}/facts`
```json
{ "feature": "steps", "value": 3 }
```
Сервер сам ставит `source="user"`, `fetchedAt=now`, `created_by`. Ответ `201` с созданным фактом.
Валидация: `steps` — 0..50; `kerbHeight` — число 0..50 или диапазон; `doorWidth` — 30..300; `incline` — 0..40; флаги — только boolean.

`POST /facts/{factId}/confirm` и `POST /facts/{factId}/dispute` — без тела.
- Повторный голос того же пользователя → `409`.
- Подтверждение: `confirmations++`, `confirmed_at=now`, +15 очков.
- Спор: `disputes++`.

### 5.4 Маршрут (прокси в ORS) — **MVP №2**
`POST /routes`
```json
{
  "points": [ { "lat": 50.0617, "lng": 19.9373 }, { "lat": 50.0541, "lng": 19.9354 } ],
  "profile": { "maxKerbCm": 3, "minWidthCm": 80, "maxInclinePct": 6 },
  "avoidCrowds": true,
  "optimizeOrder": false
}
```
Сервер вызывает `POST https://api.openrouteservice.org/v2/directions/wheelchair/geojson` с телом:
```json
{
  "coordinates": [[19.9373,50.0617],[19.9354,50.0541]],
  "instructions": true, "language": "pl", "units": "m",
  "options": { "profile_params": { "restrictions": {
      "maximum_sloped_kerb": 0.03, "minimum_width": 0.8, "maximum_incline": 6 } } }
}
```
(ORS принимает бордюр и ширину **в метрах**.)
Ответ клиенту:
```json
{
  "distanceM": 1240, "durationS": 1110,
  "geometry": [[50.0617,19.9373],[50.0612,19.9370]],
  "segments": [
    { "instruction": "Skręć w lewo w Grodzką", "distanceM": 320, "warnings": [] }
  ],
  "order": [0, 1],
  "source": "openrouteservice",
  "fallback": false
}
```
Если ORS недоступен, сервер возвращает прямую линию между точками с `"fallback": true`, а UI показывает предупреждение. Ответы кэшируются на 10 мин по хэшу запроса: у бесплатного ключа ~2000 запросов в сутки.
Профиль нигде не сохраняется и не логируется.

### 5.5 Толпы (P1)
`GET /crowd?bbox=…`
```json
{ "cells": [ { "id": "krakow:41:17", "polygon": [[50.06,19.93],…], "crowd": 0.82,
               "label": "tłoczno", "source": "survey", "reports": 12,
               "updatedAt": "2026-10-03T14:05:00Z" } ] }
```
`POST /crowd/reports`
```json
{ "lat": 50.0617, "lng": 19.9373, "level": 2 }
```
Сервер находит квадрат через `ST_Contains`. Лимит: 1 ответ на квадрат за 30 мин (иначе `429`). Начисляет +5 очков.

Пересчёт (`@Scheduled(fixedRate = 5 мин)`):
`crowd = w1·base + w2·survey + w3·live`, где
- `base` = нормированный `poi_weight` × коэффициент часа;
- `survey` = средний уровень ответов с экспоненциальным затуханием (полураспад 30 мин);
- `live` = число пользователей с активностью за 15 мин.
Квадраты, где меньше 3 пользователей, не раскрывают `live` (приватность).

### 5.6 Игра: спавн и улов (P1)
`GET /spawns?bbox=…`
```json
{ "spawns": [ { "id": "…", "lat": 50.06, "lng": 19.94, "species": "smok",
                "rarity": "epic", "expiresAt": "…" } ] }
```

`POST /catches` — `multipart/form-data`:
| часть | тип | обязательна |
|---|---|---|
| photo | image/jpeg, ≤ 3 МБ (клиент сжимает до ~1280 px) | да |
| lat, lng | double | да |
| spawnId | uuid | нет |
| placeId | string | нет |
| takenAt | ISO-8601 | да |

Проверки до отправки в Kafka:
- `spawnId` существует и не истёк;
- расстояние до спавна ≤ 50 м;
- `takenAt` не старше 10 мин;
- лимит 30 фото в сутки на пользователя.

Ответ `202 { "catchId": "…", "status": "PENDING" }`.

`GET /catches/{id}` — Flutter опрашивает раз в 1–2 с:
```json
{ "catchId": "…", "status": "OK", "points": 60, "rarity": "epic",
  "result": { "steps": 4, "kerbRange": ">7", "widthRange": null, "ramp": false,
              "handrail": true, "obstacles": ["kostka"], "difficulty": 7.4,
              "confidence": 0.82 },
  "createdFacts": ["6a0e…"] }
```

### 5.7 Профиль, награды (P1)
`GET /me` → `{ "userId", "points", "catches": 14, "barriersMapped": 23, "exploredCells": 38, "totalCells": 400 }`

`GET /rewards/offers?bbox=…` — список предложений с текущей квотой:
`available = round(base_quota × (1 − crowd(cell)))`, пересчёт раз в 15 мин.

`POST /rewards/offers/{offerId}/activate`:
1. Списывает очки (недостаточно → `402`).
2. Создаёт ваучер с `expires_at = now + 120 мин`.
3. Ответ `{ "voucherId", "code": "KBB-7F3K", "expiresAt" }`.

`GET /vouchers` — мои ваучеры (активные и истёкшие).

### 5.8 Служебное
`GET /health/sources` → содержимое `source_status`. По нему Flutter показывает баннер «Dane z dnia X — źródło chwilowo niedostępne».

---

## 6. Kafka (Redpanda)

| Топик | Кто пишет | Кто читает | Ключ |
|---|---|---|---|
| `photo.submitted` | central-api | vision-service | `catchId` |
| `photo.analyzed` | vision-service | central-api | `catchId` |
| `photo.analyzed.dlq` | central-api (после 3 ошибок) | — | `catchId` |

### 6.1 `photo.submitted`
```json
{ "catchId": "…", "photoPath": "/photos/2026/10/03/….jpg", "lat": 50.06, "lng": 19.94,
  "spawnId": "…", "placeId": null, "submittedAt": "2026-10-03T14:05:00Z" }
```
**Байты фото в Kafka не передаются**, только путь в общем томе.

### 6.2 `photo.analyzed`
```json
{ "catchId": "…", "status": "OK",
  "result": { "steps": 4, "kerbRange": ">7", "widthRange": null, "ramp": false,
              "handrail": true, "obstacles": [], "difficulty": 7.4, "confidence": 0.82 },
  "phash": "c3a1…", "reason": null }
```
`status`: `OK` / `REJECTED` (размытое фото, дубликат, на фото нет барьера) / `FAILED` (ошибка Gemini).

### 6.3 Обработка в central-api (`@KafkaListener`, в одной транзакции)
1. Найти `catch_record`. Если статус уже не `PENDING`, **выйти** (идемпотентность).
2. При `OK`:
   - обновить `ai_result` и `status`;
   - создать `accessibility_fact` с `source="ai"`, `source_ref="catch:<id>"` (только для непустых полей: `steps` → число, `kerbRange` → строка-диапазон, `ramp` → boolean);
   - начислить очки через `points_ledger` с `(reason='catch', ref_id=catchId)`;
   - увеличить `explored_count`.
3. При `REJECTED`/`FAILED` — статус и `reason`, очки не начисляются.
4. Если `confidence < 0.5`, очки делятся пополам.

Очки за редкость: common 10, rare 25, epic 60, legendary 150.

---

## 7. Импорт OSM (Overpass)

`@Scheduled(cron = "0 0 4 * * *")` плюс ручной запуск через `POST /admin/import` (с простым токеном из env).
**Один** запрос на весь bbox города, а не по запросу на каждого пользователя:
```
[out:json][timeout:90];
(
  nwr["tourism"~"attraction|museum|gallery|viewpoint"](BBOX);
  nwr["historic"](BBOX);
  nwr["amenity"~"cafe|restaurant|toilets|place_of_worship"](BBOX);
  nwr["leisure"="park"](BBOX);
);
out center tags;
```
Маппинг тегов → факты:
| Тег OSM | Факт |
|---|---|
| `wheelchair=yes` | `steps = 0` |
| `wheelchair=limited` | `steps = 1`, отдельно факт с пометкой «limited» не создаём |
| `wheelchair=no` | `steps = 3` (условно: «есть барьер») |
| `step_count=N` | `steps = N` (приоритетнее `wheelchair`) |
| `door:width` / `width` | `doorWidth` в см |
| `toilets:wheelchair=yes/no` | `toilet = true/false` |
| `ramp=yes`, `ramp:wheelchair=yes` | `ramp = true` |
| `elevator=yes` | `elevator = true` |
| `incline=6%` | `incline = 6` |

`fetched_at` = поле `timestamp` элемента OSM, если есть, иначе время импорта.
Ошибка или таймаут → 3 повтора с паузами 5 / 15 / 45 с, затем `source_status.stale = true`. Старые данные остаются.
Новый источник = новый класс, реализующий интерфейс:
```java
public interface SourceAdapter {
    String sourceId();                         // "osm", "msip"...
    List<ImportedPlace> fetch(Envelope bbox);  // места с фактами
}
```

---

## 8. Порядок работы (до 11:00)

| # | Задача | Готово, когда |
|---|---|---|
| 1 | Проект Spring Boot, docker-compose с PostGIS и Redpanda, Flyway `V1__init.sql` (city, place, accessibility_fact, app_user) | `docker compose up`, Swagger открывается |
| 2 | Seed: загрузить `mobile/assets/demo/places.json` в БД (`is_demo=true`) | `GET /places` отдаёт 11 мест |
| 3 | `GET /places`, `GET /places/{id}` + CORS | Flutter переключается на API |
| 4 | `POST /auth/anonymous` + JWT-фильтр | запросы с токеном проходят |
| 5 | `POST /routes` (ORS + кэш + fallback) | маршрут строится |
| 6 | `POST /places/{id}/facts`, `confirm`, `dispute`, `fact_vote` | кнопки в карточке работают |
| 7 | Kafka: `POST /catches`, producer, listener, `GET /catches/{id}` | фото → результат ИИ |
| 8 | Импорт Overpass по bbox центра | реальные места OSM |
| 9 | Толпы и ваучеры | если остаётся время |

Пункты 1–5 — минимум для финала, 6–7 — сильно желательно, 8–9 — если успеем.

---

## 9. Подводные камни

- **Lat/Lng.** В JTS и GeoJSON порядок координат `x=lng, y=lat`, в JSON для Flutter — поля `lat` и `lng`. Это самая частая ошибка.
- **SRID.** Задавайте `geometryFactory = new GeometryFactory(new PrecisionModel(), 4326)` и в Hibernate `columnDefinition = "geometry(Point,4326)"`.
- **jsonb в Hibernate 6:** `@JdbcTypeCode(SqlTypes.JSON)` на поле `JsonNode` / `Object` / `Map<String,Object>`.
- **`value` факта** может быть числом, boolean или строкой. Храните как `JsonNode` и отдавайте как есть.
- **Время** отдавайте в ISO-8601 с `Z`. Flutter парсит через `DateTime.parse`.
- **CORS** обязателен для Flutter Web, включая заголовок `Authorization` и метод `OPTIONS`.
- **Ключ ORS** только в env сервера, в репозиторий не коммитить.
- **Overpass** не дёргать на каждый запрос пользователя, только плановый импорт.
- **Холодный старт** Spring Boot: перед демо сделать пару запросов, чтобы прогреть.
