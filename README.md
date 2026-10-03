# Kraków bez barier

Платформа доступных и разгруженных туристических маршрутов для людей на инвалидных и детских колясках.
Полное ТЗ — [docs/TZ.md](docs/TZ.md).

## Структура (монорепо)
```
mobile/                    Flutter-приложение (Android / Web)
services/central-api/      Java · Spring Boot · PostGIS — центральный API
services/vision-service/   Python · FastAPI · OpenCV · Gemini — анализ фото
docs/                      ТЗ, правила хакатона, набросок интерфейса
```

## Архитектура
```
Flutter ──REST──► central-api (Java, PostGIS) ──topic photo.submitted──► vision-service (Python)
                        ▲                                                    │
                        └──────────── topic photo.analyzed ◄─────────────────┘
```
Брокер сообщений — Redpanda (совместим с Kafka API). В событиях передаётся ссылка на фото, а не сами байты.

## Запуск мобильного приложения
```
cd mobile
flutter pub get
flutter run -d chrome
```

## Данные
© OpenStreetMap contributors (ODbL).
