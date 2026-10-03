# Этапы реализации

Правило: один запрос = один этап. После каждого этапа — `flutter analyze`, тесты, запуск, коммит в `development`.
Если этап разрастается — делим на подэтапы (3a, 3b), а не делаем всё сразу.

## Этап 1 — прототип (до 20:00) · `mobile/`

| # | Этап | Результат / проверка | Статус |
|---|---|---|---|
| 1 | Каркас: пакеты, структура `lib/`, мятная тема, навигация по 5 экранам, рамка телефона для веба, книжная ориентация | приложение запускается, табы переключаются | ✅ |
| 2 | Модели и демо-данные: `Place`, `AccessibilityFact` (source/date/trust), `NeedsProfile`; `assets/demo/` с ~10 местами центра (включая «sprzeczne» и «brak danych») | данные загружаются, unit-тест | ✅ |
| 3 | Профиль + onboarding: пресеты Wózek inwalidzki / dziecięcy / Własne, пороги, сохранение локально | профиль сохраняется после перезапуска | ⬜ |
| 4 | Оценка соответствия (ТЗ 4.4.1): Pasuje / Częściowo / Nie pasuje / Za mało danych | unit-тесты на 4 исхода | ⬜ |
| 5 | Mapa: `flutter_map` + OSM, маркеры с иконкой и текстом, поиск, фильтры, «Lista» | места на карте, список работает | ⬜ |
| 6 | Karta miejsca: барьеры, удобства, источник, дата, бейдж доверия, конфликт данных | демо-сценарий «Wawel» | ⬜ |
| 7 | Trasa: ORS wheelchair + текстовый список сегментов (fallback — демо-маршрут) | линия на карте + список | ⬜ |
| 8 | Złap / Kolekcja / Nagrody на демо: анкета барьеров, очки, ваучер с таймером 2 ч, «DANE PRZYKŁADOWE» | главный сценарий целиком | ⬜ |
| 9 | A11y + сборка: Semantics, клавиатура, `flutter build web` | сдача прототипа, merge в `master` | ⬜ |

## Этап 2 — финал (до 11:00)

| # | Этап | Где | Статус |
|---|---|---|---|
| 10 | Overpass-адаптер во Flutter: реальные данные OSM + снимок в assets + баннер «źródło niedostępne» | `mobile/` | ⬜ |
| 11 | `docker-compose.yml`: PostGIS + Redpanda + заготовки двух сервисов | корень | ⬜ |
| 12 | central-api: Spring Boot, Flyway, сущности `place` / `accessibility_fact`, импорт Overpass, `/places`, `/places/{id}`, `/facts` | `services/central-api` | ⬜ |
| 13 | vision-service: FastAPI + Kafka consumer/producer, OpenCV-предобработка, Gemini → JSON | `services/vision-service` | ⬜ |
| 14 | central-api: `/catches` (202 + опрос), Kafka producer/consumer, очки, спавн и редкость | `services/central-api` | ⬜ |
| 15 | Толпы: сетка, базовая оценка, опрос «Jak tłoczno?», слой на карте | оба | ⬜ |
| 16 | Ваучеры: квота от толпы, активация, таймер | оба | ⬜ |
| 17 | Flutter → `ApiRepository`, перебалансировка маршрута по толпам | `mobile/` | ⬜ |
| 18 | Деплой (VPS + `docker compose up`) + README (источники, лицензии) | корень | ⬜ |
| 19 | Презентация PDF ≤10 слайдов и сценарий видео ≤3 мин (PL) | `docs/` | ⬜ |

Параллельно: этапы 12–14 можно вести в отдельных ветках (`AI` — для vision-service) и сливать в `development`.
