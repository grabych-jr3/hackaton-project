# vision-service (Python 3.12 · FastAPI · OpenCV · Gemini)

ИИ-анализ фото барьеров. Реализуется на этапе 2 (см. `docs/TZ.md`, раздел 4.4).

- Потребляет `photo.submitted` → проверка качества, ресайз, удаление EXIF, pHash-дубликаты → Gemini (structured output).
- Публикует `photo.analyzed` с JSON барьеров (диапазоны, difficulty, confidence).
- Наружу не открыт; ключ Gemini хранится только здесь.
