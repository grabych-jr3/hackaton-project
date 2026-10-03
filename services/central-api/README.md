# central-api (Java 21 · Spring Boot 3 · PostGIS)

Центральный API для мобильного приложения. Реализуется на этапе 2 (см. `docs/TZ.md`, разделы 9.2–9.4).

- REST `/api/v1/...` для Flutter: места, факты доступности, маршруты (прокси к OpenRouteService), толпы, игра, ваучеры.
- Импорт OpenStreetMap (Overpass) по расписанию.
- Kafka API (Redpanda): публикует `photo.submitted`, потребляет `photo.analyzed`.
