# Kraków bez barier

Aplikacja, która pomaga osobom poruszającym się na **wózkach inwalidzkich** i **rodzicom z wózkami dziecięcymi** ocenić dostępność miejsc i tras w Krakowie — według ich własnych progów (schody, krawężnik, szerokość przejścia, nachylenie), a nie jednego hasła „dostępne / niedostępne”.

Każda informacja o dostępności ma **źródło, datę i poziom wiarygodności**. Dane niepotwierdzone są wyraźnie oznaczone, a **brak danych nigdy nie oznacza „dostępne”**. Element grywalizacji (zbieranie stworków za zgłaszanie barier, vouchery w mniej zatłoczonych miejscach) motywuje do uzupełniania mapy i rozprasza ruch turystyczny.

> Prototyp hackathonowy. Dane oznaczone **„DANE PRZYKŁADOWE”** są demonstracyjne i nie opisują rzeczywistego stanu obiektów.

## Co działa w prototypie (MVP)

| Funkcja | Status |
|---|---|
| Profil potrzeb (wózek inwalidzki / dziecięcy / własne progi), zapisywany tylko na urządzeniu, bez pytań o niepełnosprawność | ✅ |
| Mapa z oceną miejsc dla profilu: Pasuje / Częściowo / Nie pasuje / Za mało danych | ✅ |
| Lista miejsc — tekstowa alternatywa mapy, wyszukiwanie i filtry | ✅ |
| Karta miejsca: bariery i udogodnienia, źródło, data, wiarygodność, ostrzeżenie o danych sprzecznych | ✅ |
| Trasa dla wózka (OpenRouteService, profil `wheelchair`) z listą odcinków; bez klucza / sieci — oznaczona trasa przykładowa | ✅ |
| GPS, warstwy mapy (ciemna / ulice / satelita) | ✅ |
| Zgłaszanie barier (ankieta), kolekcja stworków, punkty, vouchery ważne 2 h | ✅ (dane przykładowe) |
| Backend: Java Spring Boot + PostGIS, analiza zdjęć Python + Gemini, Kafka (Redpanda) | 🛠 w repozytorium, poza MVP |

## Uruchomienie aplikacji (Flutter)

Wymagania: Flutter 3.41+, Chrome.

```bash
cd mobile
flutter pub get
flutter run -d chrome
```

Trasa z OpenRouteService wymaga klucza (bezpłatny: openrouteservice.org). Skopiuj `mobile/config/secrets.example.json` do `mobile/config/secrets.json` (plik jest w `.gitignore`), wpisz klucz i uruchom:

```bash
flutter run -d chrome --dart-define-from-file=config/secrets.json
```

Bez klucza aplikacja działa, a trasa jest pokazywana jako **przykładowa** (z oznaczeniem).

Budowa wersji web: `flutter build web --release` → katalog `mobile/build/web`.

## Backend (poza MVP)

```bash
cp .env.example .env      # uzupełnij klucze
docker compose up --build # PostGIS, Redpanda, central-api :8080, vision-service :8000
```

Szczegóły: [docs/BACKEND.md](docs/BACKEND.md), `services/central-api/README.md`, `services/vision-service/README.md`.

## Struktura repozytorium

```
mobile/                    aplikacja Flutter (Android / Web)
services/central-api/      Java 21 · Spring Boot · PostGIS — centralne API
services/vision-service/   Python · FastAPI · OpenCV · Gemini — analiza zdjęć barier
docs/                      specyfikacja (TZ), plan etapów, plan backendu, regulamin wyzwania
docker-compose.yml         cały backend jednym poleceniem
```

## Źródła danych i licencje

| Źródło | Zastosowanie | Licencja / warunki |
|---|---|---|
| OpenStreetMap (Overpass API) | obiekty, tagi dostępności (`wheelchair`, `kerb`, `step_count`, `toilets:wheelchair` …) | © OpenStreetMap contributors, ODbL |
| OpenRouteService | trasy dla wózków (`wheelchair`) | HeiGIT, darmowy klucz z limitami; dane © OpenStreetMap contributors |
| Esri (World Street Map, World Dark Gray, World Imagery) | podkłady mapowe | © Esri, HERE, Garmin, Maxar, OpenStreetMap contributors — wymagana atrybucja |
| Zgłoszenia użytkowników | fakty o barierach | oznaczane jako niezweryfikowane do czasu potwierdzenia |
| Google Gemini (backend) | wstępna analiza zdjęć barier | wynik oznaczany „AI · niezweryfikowane” |
| Portal Otwarte Dane Kraków, MSIP | planowane kolejne adaptery źródeł | zgodnie z licencją danego zbioru |

Nie korzystamy z danych pobieranych bez zgody dostawcy (np. Google Popular Times).

## Dokumentacja

- Specyfikacja techniczna: [docs/TZ.md](docs/TZ.md) / [docs/TZ.pdf](docs/TZ.pdf)
- Plan etapów: [docs/ETAPY.md](docs/ETAPY.md)
- Backend (encje, API, Kafka): [docs/BACKEND.md](docs/BACKEND.md)
