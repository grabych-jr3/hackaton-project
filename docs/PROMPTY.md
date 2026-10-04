# Промпты для следующих функций

Как пользоваться:
1. Берёте одну функцию. Копируете **общий контекст** (раздел 0) и промпт этой функции в свою ИИ (Claude, ChatGPT, Cursor…) или делаете сами.
2. Работаете в отдельной ветке от `development`: `git checkout development && git pull && git checkout -b feature/<имя>`.
3. Готовую ветку пушите в GitHub (`git push -u origin feature/<имя>`) и пишете мне: «проверь feature/<имя>».
4. Я проверяю по чек-листу (раздел «Что я проверю»), исправляю мелочи и сливаю в `development`.

Функции независимы друг от друга, их можно делать параллельно разными людьми. Порядок в списке — по ценности для жюри.

---

## 0. Общий контекст (вставлять в начало каждого промпта)

```
Проект «Kraków bez barier» — монорепозиторий https://github.com/grabych-jr3/hackaton-project (ветка development).
Приложение помогает людям на инвалидных и детских колясках оценивать доступность мест и маршрутов в Кракове.
Тексты интерфейса — на польском. Тёмная тема, цвета только из mobile/lib/core/theme/app_colors.dart.

Структура:
- mobile/ — Flutter 3.41 (Riverpod, go_router, flutter_map). Модели: mobile/lib/data/models/, игра: mobile/lib/features/game/.
  Режимы: без --dart-define=API_BASE_URL — демо-данные из assets; с API_BASE_URL=http://localhost:8080/api/v1 — бэкенд.
- services/central-api/ — Java 21, Spring Boot 3, PostgreSQL + PostGIS (Flyway), Spring Kafka. Контракт API: docs/BACKEND.md.
- services/vision-service/ — Python 3.12, FastAPI, OpenCV, Gemini; Kafka-топики photo.submitted / photo.analyzed.
- docker-compose.yml в корне поднимает db, redpanda, central-api (:8080), vision-service (:8000). Секреты — в .env (не коммитить).

Обязательные правила (требования хакатона):
- У каждого факта о доступности есть источник, дата и статус достоверности. Непроверенное нельзя показывать как подтверждённое.
- Отсутствие данных никогда не означает «доступно».
- Демо-данные помечаются бейджем «DANE PRZYKŁADOWE» (виджет DemoBadge в mobile/lib/features/place/status_chip.dart).
- Доступность (WCAG 2.2 AA): Semantics-подписи, управление с клавиатуры, контраст ≥ 4.5:1, статус не только цветом.
- Профиль потребностей пользователя не отправляется на сервер (кроме порогов в запросе маршрута).
- Не коммитить ключи API.

Перед сдачей:
- mobile/: `flutter analyze` → No issues found!, `flutter test` → все тесты зелёные (сейчас их 36+), добавить свои тесты.
- services/central-api: `./gradlew build` проходит; новые таблицы — только новой Flyway-миграцией (V3__..., V4__...).
- services/vision-service: `pytest` проходит.
- Не менять чужие функции без необходимости; новый код — в новых файлах/папках.
```

---

## 1. Толпы: сетка, опрос «Jak tłoczno?», слой на карте

```
Задача: реализовать загруженность районов (ТЗ docs/TZ.md, раздел 6; контракт docs/BACKEND.md, раздел 5.5).

Бэкенд (services/central-api):
- Flyway-миграция: заполнить grid_cell сеткой 250×250 м по bbox Кракова (таблица уже есть), посчитать poi_weight из мест (place).
- POST /api/v1/crowd/reports (auth) {lat,lng,level:0|1|2} → находит квадрат через ST_Contains, лимит 1 ответ на квадрат за 30 мин (иначе 429), +5 очков через points_ledger.
- @Scheduled каждые 5 мин: crowd = w1·base + w2·survey + w3·live (base = нормированный poi_weight × коэффициент часа; survey = ответы с затуханием, полураспад 30 мин). Сохранять в crowd_snapshot.
- GET /api/v1/crowd?bbox=… → {cells:[{id, polygon:[[lat,lng]…], crowd:0..1, label:"luźno|średnio|tłoczno", source:"estimate|survey", reports, updatedAt}]}.
- Тесты: расчёт crowd, лимит 429.

Flutter (mobile):
- Новая папка lib/features/crowd/: модель, репозиторий (API + демо-режим с assets/demo/crowd.json, помечен DANE PRZYKŁADOWE), провайдер.
- Слой полупрозрачных квадратов на карте (PolygonLayer) с переключателем; цвет + текстовая подпись уровня; в режиме «Lista» — текстом рядом с местом.
- Кнопка/шит «Jak tłoczno?» с тремя большими кнопками (luźno / średnio / tłoczno), Semantics-подписи.
- В карточке места строка «Tłok: średnio · szacunek (OSM + pora dnia)» или «12 osób zgłosiło, 8 min temu».
- Виджет-тесты: слой рисуется, опрос отправляет запрос, в демо-режиме бейдж.

Сдать: ветка feature/crowd.
```

---

## 2. Настоящая камера: фото → ИИ → результат

```
Задача: в экране Złap (mobile/lib/features/catch/catch_screen.dart, режим «Kamera») сделать настоящий снимок и анализ.

Flutter:
- Пакет image_picker (камера на Android, выбор файла на web). Сжатие до ~1280 px, JPEG 80%.
- Если API включён: POST /api/v1/catches (multipart: photo, lat, lng, takenAt, placeId?) → 202 {catchId}; опрос GET /api/v1/catches/{id} каждые 1.5 с до статуса OK|REJECTED|FAILED (таймаут 30 с).
- Показ результата: найденные барьеры (steps, kerbRange, widthRange, ramp…), confidence, бейдж «AI · niezweryfikowane», очки. REJECTED — причина на польском (приходит из vision-service). FAILED — «AI niedostępne, użyj ankiety» + переход в режим «Ankieta».
- Без API: оставить текущее поведение (анкета / демо), без фальшивого «анализа ИИ».
- Разрешения камеры: AndroidManifest + Info.plist (NSCameraUsageDescription по-польски).
- Тесты с MockClient: успешный анализ, REJECTED, FAILED, таймаут.

Бэкенд: эндпоинты уже есть (docs/BACKEND.md 5.6 и 6). Проверить, что catch без spawnId принимается, и что факты AI создаются, если передан placeId.

Сдать: ветка feature/camera-ai.
```

---

## 3. Существа на карте (спавн) и приманка

```
Задача: существа появляются на карте в «трудных» местах (ТЗ раздел 7.1–7.2).

Бэкенд:
- @Scheduled каждые 10 мин: для grid_cell считать difficulty (доля фактов со ступенями/высоким бордюром/wheelchair=no, плюс «дыры в данных» — места без фактов), создавать creature_spawn (TTL 30 мин), редкость = 0.5·difficulty + 0.3·unexplored + 0.2·(1 − crowd).
- GET /api/v1/spawns?bbox=… → {spawns:[{id,lat,lng,species,rarity,expiresAt}]}.
- POST /api/v1/baits (auth) {lat,lng} → −50 очков, ×3 шанс спавна в радиусе 50 м на 24 ч.
- Тесты: формула редкости, TTL, списание очков.

Flutter:
- Слой маркеров существ на карте (эмодзи из каталога, редкость текстом в Semantics), нажатие → переход в Złap с выбранным spawnId.
- Кнопка «Postaw przynętę» в Złap (подтверждение, списание очков).
- Демо-режим: assets/demo/spawns.json + бейдж.

Сдать: ветка feature/spawns.
```

---

## 4. Ваучеры с квотой по загруженности

```
Задача: количество доступных ваучеров у партнёра зависит от толпы в его квадрате (ТЗ раздел 8).
Зависит от функции 1 (crowd); если её ещё нет — брать crowd = 0.5.

Бэкенд:
- GET /api/v1/game/catalog: у каждой offer добавить поле available = round(base_quota × (1 − crowd(cell))) и crowdLabel; пересчёт раз в 15 мин.
- POST /api/v1/game/vouchers: если available = 0 → 409 {error:"NO_QUOTA"}; при активации available−1.
- Тесты: квота, 409.

Flutter (Nagrody):
- Показ «Dostępne: 3 · spokojnie teraz» у предложения; кнопка неактивна при 0 с подписью «Brak voucherów — wróć, gdy będzie mniej ludzi».
- Сортировка: сначала предложения в спокойных районах.
- Тесты экрана.

Сдать: ветка feature/voucher-quota.
```

---

## 5. Реальные места из OpenStreetMap

```
Задача: вместо 11 демо-мест показывать реальные места центра Кракова из OSM.

Бэкенд:
- Импорт Overpass уже есть (POST /api/v1/admin/import с заголовком X-Admin-Token). Проверить на реальных данных: маппинг тегов (docs/BACKEND.md раздел 7), fetched_at из timestamp OSM, повторный импорт обновляет, а не дублирует.
- GET /places?bbox=…: поддержать до 2000 мест, параметр category, сортировка по расстоянию от центра bbox.
- Демо-места (is_demo) не смешивать: параметр includeDemo=false по умолчанию в API-режиме.

Flutter:
- Загрузка мест по видимой области карты (bbox при движении карты, debounce 500 мс).
- Кластеризация маркеров при большом количестве (пакет flutter_map_marker_cluster или своя группировка).
- Источник «OpenStreetMap, edycja <дата>» в карточке.

Сдать: ветка feature/osm-places.
```

---

## 6. Маршрут из нескольких точек с перестановкой по толпам

```
Задача: «Zaplanuj trasę» по 2–5 местам, порядок остановок подстраивается под толпу (ТЗ раздел 4.3).

Бэкенд: POST /api/v1/routes с optimizeOrder=true — перебор перестановок (≤6 точек), стоимость = время пути + λ·Σ crowd(ETA)·время в точке; ответ с полем order.
Flutter: выбор нескольких мест (чекбоксы в Lista или «Dodaj do trasy» в карточке), список остановок с временем и уровнем толпы, кнопка «Przelicz wg tłumów», текстовое объяснение «Wawel teraz zatłoczony — przesunięty na 16:00».
Тесты: перестановка на фиктивных данных.

Сдать: ветка feature/route-multi.
```

---

## 7. Доступность: финальная проверка WCAG

```
Задача: пройти главный сценарий только клавиатурой и с экранным диктором (NVDA на Windows / TalkBack на Android) и починить найденное.
- Порядок фокуса Tab на всех экранах, видимый фокус, Esc закрывает панели.
- Всё на карте доступно в «Lista»; маршрут — текстовым списком.
- Тест на перемещение фокуса Tab между вкладками (сейчас не покрыт).
- Документ docs/WCAG.md: что проверено, найденные ограничения и план их устранения (это требуется правилами хакатона).

Сдать: ветка feature/wcag.
```

---

## 8. Видео (до 3 минут) — не код

```
Сценарий для записи с экрана (польский закадр или субтитры):
0:00 проблема (слайд 2) → 0:20 выбор профиля «Wózek inwalidzki» → 0:35 карта, фильтр «Pasujące do mnie», переключение на Lista →
0:55 карточка Wawel: источник, дата, статус → 1:15 Sukiennice: «Dane sprzeczne», Nowa Prowincja: «Brak danych ≠ dostępne» →
1:35 трасса Rynek → Wawel с листой odcinków → 2:00 Złap: ankieta → stworek, Kolekcja → 2:25 Nagrody: voucher 2 h →
2:45 итог: источники OSM/ORS, WCAG, модель бизнеса, ссылка на демо.
Видео выложить в открытый репозиторий (например, в Releases на GitHub или YouTube unlisted) — требование хакатона.
```

---

## Что я проверю при приёме

1. Ветка от актуальной `development`, нет конфликтов, нет секретов (`.env`, ключи).
2. `flutter analyze`, `flutter test`, `./gradlew build`, `pytest` — зелёные.
3. Контракт API совпадает с `docs/BACKEND.md` (и документ обновлён, если появились новые эндпоинты).
4. Демо-режим (без API) по-прежнему работает и помечен «DANE PRZYKŁADOWE».
5. Правила достоверности: источник/дата/статус, «brak danych ≠ dostępne», непроверенное не выдаётся за подтверждённое.
6. Доступность: Semantics, клавиатура, контраст, без переполнений экрана 412×915.
7. Запуск через `docker compose up --build` и проверка сценария вручную.
