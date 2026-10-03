# AR Update — Вариант C (гибридный AR-оверлей)

Эта папка содержит обновлённые/новые файлы для реализации камеры с AR-оверлеем
вместо ручной анкеты в экране «Złap».

## Что изменено

### Новые файлы
- `lib/features/catch/ar_catch_screen.dart` — экран камеры с AR-оверлеем спрайта
- `lib/data/repositories/catch_repository.dart` — репозиторий для отправки фото на бэкенд

### Обновлённые файлы
- `pubspec.yaml` — добавлены пакеты `camera`, `sensors_plus`, `flutter_compass`, `http`
- `lib/app.dart` — добавлен маршрут `/catch/camera` на `ArCatchScreen`
- `lib/features/game/game_models.dart` — добавлена модель `CatchPhotoResponse`
- `lib/features/game/game_providers.dart` — добавлен `catchRepositoryProvider` и метод `submitPhoto()`
- `lib/features/catch/catch_screen.dart` — добавлена кнопка «Użyj kamery» для перехода на AR-экран
- `android/app/src/main/AndroidManifest.xml` — добавлен пермишен `CAMERA`
- `ios/Runner/Info.plist` — добавлен `NSCameraUsageDescription`

## Как применить
Скопируйте файлы из этой папки в `mobile/`, заменяя существующие.
Затем выполните `flutter pub get`.
