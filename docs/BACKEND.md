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
  "profile": { "maxSteps": 0, "maxKerbCm": 3, "minWidthCm": 80, "maxInclinePct": 6 },
  "avoidCrowds": true,
  "optimizeOrder": false
}
```
`maxSteps`: `0` — никаких ступеней (коляска), `>0` — пара ступеней допустима (детская коляска), не задан — как 0. `minWidthCm` по умолчанию 75.

**Логика (продуктовое правило: по умолчанию — обычный пешеходный маршрут, недоступные участки красным, доступная альтернатива рядом):**
1. **Основной маршрут** — `POST /v2/directions/foot-walking/geojson` (без restrictions).
2. По `extras` основного маршрута строятся `barriers` — диапазоны индексов его `geometry`, непроходимые для профиля.
3. Если `barriers` не пуст — дополнительно считается **альтернатива** `POST /v2/directions/wheelchair/geojson` с restrictions; у альтернативы тоже вычисляются собственные `barriers`. Если ORS не нашёл маршрут (коды 2004/2009/2010/2099) или альтернатива всё ещё с барьерами — пробуются смещённые точки назначения (`RouteService.DEST_OFFSETS_M`, 40–85 м вокруг цели; первая без барьеров побеждает) и в альтернативу добавляется `"note": "Brak trasy bez barier do samego celu — ostatnie N m może wymagać pomocy"` (если конец дальше 15 м от цели). Иначе — один повтор **без** `profile_params.restrictions` → альтернатива с `"relaxed": true, "accessible": false` и `note`. Если и это не удалось — `"alternative": null`, а у основного маршрута `note` с объяснением. Пример: Stara Synagoga (50.0514,19.9485) — точная цель привязывается к изолированному куску графа wheelchair (ORS 2009 даже без restrictions), смещение на 40 м к северу даёт маршрут.
   Клиент показывает барьеры, альтернативу и `note` только при включённом чипе «Pasujące do mnie».
4. Если не удался основной маршрут (или нет ключа) — прямая линия с `"fallback": true` и `fallbackReason`.

Тело запроса в ORS (оба профиля):
```json
{
  "coordinates": [[19.9373,50.0617],[19.9354,50.0541]],
  "radiuses": [-1, -1],
  "instructions": true, "language": "pl", "units": "m",
  "extra_info": ["steepness", "surface", "waytype"],
  "options": { "profile_params": { "restrictions": {
      "maximum_sloped_kerb": 0.03, "minimum_width": 0.8, "maximum_incline": 6 } } }
}
```
(`options` — только для wheelchair. ORS принимает бордюр и ширину **в метрах**. `radiuses: -1` — привязка к ближайшей дороге без ограничения расстояния: без этого точки во дворах/полях дают 2010 «Could not find routable point within a radius of 150 m».)

**Правила `barriers`** (идентификаторы ORS extra_info, проверены на реальном ответе у Вавеля):
| type | источник | когда барьер | label / detail |
|---|---|---|---|
| `steps` | `waytype` = 8 | всегда | `"Schody"` / `null`; при `maxSteps > 0` — `"sprawdź liczbę stopni"` |
| `steep` | `steepness` класс ±1=1–3 %, ±2=4–6 %, ±3=7–9 %, ±4=10–15 %, ±5=≥16 % | нижняя граница класса > `maxInclinePct` (по умолч. 6) | `"Stromy odcinek"` / `"ok. 2%"`…`"ok. 12%"`, `"ponad 15%"` |
| `surface` | `surface` 2 unpaved, 5 cobblestone, 8–10 gravel, 11–12 dirt/ground, 13 ice, 15 sand, 16 woodchips, 17 grass, 18 grass paver | только при `maxKerbCm <= 3` (пресет коляски; без профиля — тоже) | `"Nawierzchnia: kostka brukowa"` и т. п. / `null` |
| `narrow` | — | зарезервирован: ORS extras не дают ширину, сейчас не выдаётся | |

Соседние/перекрывающиеся диапазоны одного типа сливаются (для `steep` остаётся самый крутой `detail`, для `surface` — только с одинаковым label). Список отсортирован по `fromIndex`.
Те же extras дают `segments[].warning` (польский текст, напр. `"Schody"`, `"Stromy odcinek (ok. 8%)"`, `"Nawierzchnia: kostka brukowa"`, несколько через `"; "`), сопоставляя `way_points` шага с диапазонами extras.

Ответ клиенту:
```json
{
  "profile": "foot-walking",
  "distanceM": 643.2, "durationS": 463.1,
  "geometry": [[50.0560,19.9340],[50.0559,19.9341]],
  "segments": [
    { "instruction": "Skręć w lewo na Podzamcze", "distanceM": 120, "warning": "Schody" }
  ],
  "order": [0, 1],
  "source": "openrouteservice",
  "fallback": false,
  "relaxed": false,
  "fallbackReason": null,
  "barriers": [
    { "fromIndex": 12, "toIndex": 13, "type": "steps", "label": "Schody", "detail": null },
    { "fromIndex": 25, "toIndex": 41, "type": "steep", "label": "Stromy odcinek", "detail": "ponad 15%" }
  ],
  "accessible": false,
  "alternative": {
    "profile": "wheelchair", "distanceM": 910, "durationS": 700, "geometry": [[50.0560,19.9340]], "segments": [],
    "order": [0, 1], "source": "openrouteservice", "fallback": false, "relaxed": false, "fallbackReason": null,
    "barriers": [], "accessible": true, "alternative": null
  }
}
```
- `accessible` = `barriers` пуст и данные есть. У альтернативы `barriers` всегда `[]`, `accessible` = `!relaxed`.
- `relaxed` (bool, по умолч. false) — маршрут построен без ограничений профиля; UI должен предупредить.
- `fallbackReason` (string|null) — при `fallback: true`, по-польски, напр. `"Brak klucza OpenRouteService"`, `"OpenRouteService: nie znaleziono trasy (kod 2009) - Route could not be found …"`, `"OpenRouteService: usługa niedostępna"`.
- Fallback: прямая линия, `"source": "straight-line"`, `"barriers": []`, `"accessible": false`, `"alternative": null` — клиент показывает «Brak danych o dostępności trasy».

Ошибки ORS логируются WARN (профиль ORS, код, HTTP-статус) — без ключа, координат и порогов профиля. Ответы (кроме fallback) кэшируются на 10 мин по запросу: у бесплатного ключа ~2000 запросов в сутки.
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

`POST /catches` (auth) — `multipart/form-data`:
| часть | тип | обязательна |
|---|---|---|
| photo | JPEG или PNG (проверка по сигнатуре), ≤ 5 МБ (клиент сжимает до ~1280 px) | да |
| lat, lng | double | да |
| takenAt | ISO-8601 UTC | да |
| spawnId | uuid | нет (спавны ещё не генерируются) |
| placeId | string | нет |

Проверки до отправки в Kafka:
- `takenAt` не старше 10 мин (и не более 2 мин в будущем) → `400`;
- размер > 5 МБ → `413 PAYLOAD_TOO_LARGE`; не JPEG/PNG → `400`;
- если передан `spawnId`: существует (`404`), не истёк (`410 SPAWN_EXPIRED`), расстояние ≤ 50 м (`400`); без `spawnId` проверки расстояния нет;
- `placeId` (если есть) существует → иначе `404`;
- лимит 30 фото в сутки на пользователя → `429`.

Ответ `202 { "catchId": "…", "status": "PENDING", "createdAt": "2026-10-04T10:00:00Z", "thumbnailUrl": "/catches/{id}/photo" }`.
Фото сохраняется сразу, анализ идёт в фоне — приложение не блокирует пользователя, результаты забирает через `GET /catches?since=…`.

`GET /catches/{id}` (auth, только владелец, чужой → `404`) — Flutter опрашивает раз в 1–2 с:
```json
{ "catchId": "…", "status": "OK", "reason": null,
  "result": { "steps": 5, "kerbRange": null, "widthRange": null, "ramp": false,
              "handrail": false, "obstacles": [], "difficulty": 10.0, "confidence": 1.0 },
  "species": { "id": "niedzwiedz", "name": "Niedźwiedź", "emoji": "🐻", "rarity": "epic" },
  "points": 60, "awarded": 0,
  "state": { "points": 120, "caught": { "niedzwiedz": 1 }, "vouchers": [] },
  "createdFacts": [] }
```
- `status`: `PENDING` / `OK` / `REJECTED` / `FAILED`; `reason` — польский текст для пользователя при `REJECTED`/`FAILED`.
- `species`, `points` (= `sellValue` вида), `state` (как `GET /game/state`) — только при `OK`, иначе `null`. `awarded` всегда 0.
- **Поимка по фото очков не даёт** (как `/game/reports`): +1 в `user_species`, очки — только через `POST /game/sell`.

`GET /catches?since=<ISO>&limit=20` (auth) — мои уловы, новые сверху (`created_at DESC`), `limit` 1…100 (по умолчанию 20). Ответ — JSON-массив:
```json
[ { "catchId": "…", "status": "OK", "reason": null,
    "species": { "id": "kerbik", "name": "Kerbik", "emoji": "🧱", "rarity": "rare" }, "points": 25,
    "result": { "steps": 3, "…": "…" },
    "createdAt": "2026-10-04T10:00:00Z", "analyzedAt": "2026-10-04T10:00:05Z",
    "placeId": "osm:node/1", "thumbnailUrl": "/catches/…/photo" } ]
```
- без `since` — все (до `limit`); с `since` — только `analyzedAt > since` **или** `status = PENDING` (опрос «что завершилось с прошлой проверки»: клиент хранит время последнего опроса).
- `species`/`points`/`result` — `null`, пока не `OK` (у `REJECTED`/`FAILED` `result` может быть заполнен).

`GET /catches/{id}/photo` (auth, только владелец, чужой → `404`) — байты сохранённого фото, `Content-Type` `image/jpeg` или `image/png` (по расширению файла), `Cache-Control: private, max-age=86400`. `thumbnailUrl` — относительный путь к нему (префикс `/api/v1` добавляет клиент, нужен `Authorization`).

Таймаут анализа: `@Scheduled` каждые 30 с переводит уловы в `PENDING` дольше 2 мин в `FAILED` с `reason = "Analiza nie powiodła się — spróbuj ponownie"` (vision недоступен). Обновление идёт только `WHERE status = 'PENDING'`, а listener берёт строку `FOR UPDATE` и тоже обрабатывает только `PENDING`, — гонки нет: кто первый, тот и задаёт итоговый статус, поздний `photo.analyzed` игнорируется.

### 5.7 Профиль, награды (P1)
`GET /me` → `{ "userId", "points", "catches": 14, "barriersMapped": 23, "exploredCells": 38, "totalCells": 400 }`

`GET /rewards/offers?bbox=…` — список предложений с текущей квотой:
`available = round(base_quota × (1 − crowd(cell)))`, пересчёт раз в 15 мин.

`POST /rewards/offers/{offerId}/activate`:
1. Списывает очки (недостаточно → `402`).
2. Создаёт ваучер с `expires_at = now + 120 мин`.
3. Ответ `{ "voucherId", "code": "KBB-7F3K", "expiresAt" }`.

`GET /vouchers` — мои ваучеры (активные и истёкшие).

### 5.7a Игра v2: анкета барьера (реализовано, контракт v2)
Правила — порт `mobile/lib/features/game/game_models.dart` (`GameRules`), случайность на сервере.
Ошибки: `{ "error": CODE, "code": CODE, "message" }` (клиент читает `code`).

- `GET /game/catalog` (public) → копия `mobile/assets/demo/game.json` (`dataset, isDemo, initialPoints, species[], offers[], districts[]`). У каждого вида есть `sellValue` (common 10, rare 25, epic 60, legendary 150) и польское `description`.
- `GET /game/state` (auth) → `{ "points": 120, "caught": { "golab": 2 }, "vouchers": [ { "offerId", "code", "activatedAt", "expiresAt" } ] }`. Новый пользователь получает `initialPoints` (120) при первом `/auth/anonymous`.
- `POST /game/reports` (auth)
  ```json
  { "placeId": "wawel", "report": { "placeId": "wawel", "steps": 3, "curb": "high", "passage": "narrow",
    "noRamp": true, "uneven": false, "obstacles": false } }
  ```
  `curb` ∈ none|low|mid|high, `passage` ∈ none|wide|medium|narrow.
  severity: steps>0 → +1 (≥3 → +2); curb mid +1, high +2; passage medium +1, narrow +2; noRamp +2; uneven +1; obstacles +1.
  score = severity + random(0..3): ≥10 legendary (150), ≥6 epic (60), ≥3 rare (25), иначе common (10); вид — случайный из этой редкости.
  Ответ: `{ "species": {id,name,emoji,rarity}, "points": 60, "awarded": 0, "state": GameState }`.
  **Поимка очков не даёт** (`state.points` не меняется, `caught[speciesId]` +1); `points` = цена продажи этого вида, `awarded` всегда 0.
  Если есть placeId — создаются факты `source=user` (`sourceRef=report:<id>`): steps>0 → `steps`; curb low/mid/high → `kerbHeight` "0-3"/"3-7"/">7"; passage wide/medium/narrow → `doorWidth` ">90"/"70-90"/"<70"; noRamp → `ramp=false`.
- `POST /game/sell` (auth) `{ "speciesId": "smok", "count": 1 }` → `{ "earned": 150, "state": GameState }`.
  earned = count × sellValue(rarity); `caught[speciesId]` уменьшается на count (ключ удаляется при 0); очки — через `points_ledger` (reason `sell`).
  `400 INVALID_COUNT` (count < 1), `409 NOT_ENOUGH_CREATURES` (count > есть у пользователя), `404 NOT_FOUND` (неизвестный вид).
- `POST /game/vouchers` (auth) `{ "offerId" }` → `{ "voucher": {offerId,code:"KBB-XXXX",activatedAt,expiresAt}, "state" }`; срок 120 мин.
  `402 INSUFFICIENT_POINTS`, `403 OFFER_NOT_VERIFIED`, `404 NOT_FOUND`.
- Маршруты: если в `/routes` нет `profile.minWidthCm`, используется 75 см (0.75 м, `minimum_width` для ORS); поле по-прежнему принимается.
- Хранение: `user_species`, `game_report`, `game_voucher` (V2), очки — `app_user.points` + `points_ledger`.

### 5.8 Служебное
`GET /health` и `GET /api/v1/health` → `{ "status": "UP" }` (public, клиент определяет доступность сервера).
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
1. Найти `catch_record` (`FOR UPDATE`). Если статус уже не `PENDING`, **выйти** (идемпотентность: повтор сообщения ничего не меняет).
2. При `REJECTED`/`FAILED` — статус и `reason` от vision-service (например «Zdjęcie jest nieostre — zrób ponownie», «Zdjęcie jest zbyt ciemne — zrób ponownie»), существо не выдаётся.
3. При `OK`:
   - **дубликат**: pHash с расстоянием Хэмминга ≤ 6 у другого `OK`-улова в радиусе 30 м → `status=REJECTED`, `reason="To miejsce zostało już sfotografowane"`, существо не выдаётся;
   - если есть `placeId` — `accessibility_fact` с `source="ai"`, `source_ref="catch:<id>"` (только непустые: `steps`, `kerbRange` → `kerbHeight`, `ramp`);
   - результат ИИ → `BarrierReport` и те же правила, что `/game/reports` (`GameRules`): `steps` → steps; `kerbRange` "0-3"/"3-7"/">7" → curb low/mid/high; `widthRange` "<70"/"70-90"/">90" → passage narrow/medium/wide; `ramp=false` → noRamp; непустой `obstacles` → obstacles; `difficulty ≥ 6` → uneven. severity + random(0..3) → редкость → случайный вид;
   - `user_species` +1, `catch_record.species_id`, `points=0`; **очки не начисляются** (никаких записей в `points_ledger`);
   - увеличить `explored_count`.

Хранение: `catch_record.species_id` (миграция V3).

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
