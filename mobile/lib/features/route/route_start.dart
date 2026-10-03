import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

/// Default start when GPS is off, inaccurate or far away: Rynek Główny.
const rynekGlowny = LatLng(50.0617, 19.9373);

/// GPS is used only within this distance of the Rynek…
const maxGpsDistanceM = 15000.0;

/// …and only when the reported accuracy is at least this good.
const maxGpsAccuracyM = 300.0;

/// Accuracy above this is flagged to the user as imprecise.
const warnAccuracyM = 150.0;

/// A GPS fix with its reported accuracy radius (meters).
class UserLocation {
  const UserLocation(this.point, {this.accuracyM = 0});
  final LatLng point;
  final double accuracyM;

  bool get isFarFromKrakow =>
      const Distance()(point, rynekGlowny) >= maxGpsDistanceM;
  bool get isAccurate => accuracyM <= maxGpsAccuracyM;
  bool get isUsable => !isFarFromKrakow && isAccurate;
}

/// "±40 m" / "±1,2 km" (Polish decimal comma).
String formatAccuracy(double m) => m >= 1000
    ? '±${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
    : '±${m.round()} m';

enum StartKind { manual, gps, rynek }

/// What the user prefers; [auto] = manual > GPS > Rynek.
enum StartPreference { auto, manual, gps, rynek }

class StartSelection {
  const StartSelection(this.kind, this.point, this.label);
  final StartKind kind;
  final LatLng point;
  final String label;
}

/// Start order: manual > GPS (≤ 15 km, accuracy ≤ 300 m) > Rynek Główny.
/// A non-auto [preference] is honoured when that option is available.
StartSelection selectStart({
  LatLng? manual,
  UserLocation? gps,
  StartPreference preference = StartPreference.auto,
}) {
  StartSelection? manualSel() => manual == null
      ? null
      : StartSelection(StartKind.manual, manual, 'Wybrany punkt');
  StartSelection? gpsSel() => gps == null || !gps.isUsable
      ? null
      : StartSelection(StartKind.gps, gps.point,
          'Twoja lokalizacja (${formatAccuracy(gps.accuracyM)})');
  StartSelection rynekSel() {
    final why = gps == null
        ? 'lokalizacja niedostępna'
        : gps.isFarFromKrakow
            ? 'poza Krakowem'
            : 'lokalizacja niedokładna';
    final suffix = (manual == null && gpsSel() == null) ? ' ($why)' : '';
    return StartSelection(StartKind.rynek, rynekGlowny, 'Rynek Główny$suffix');
  }

  switch (preference) {
    case StartPreference.manual:
      return manualSel() ?? gpsSel() ?? rynekSel();
    case StartPreference.gps:
      return gpsSel() ?? manualSel() ?? rynekSel();
    case StartPreference.rynek:
      return rynekSel();
    case StartPreference.auto:
      return manualSel() ?? gpsSel() ?? rynekSel();
  }
}

/// Start options currently available, in cycling order.
List<StartKind> availableStarts({LatLng? manual, UserLocation? gps}) => [
      StartKind.rynek,
      if (gps != null && gps.isUsable) StartKind.gps,
      if (manual != null) StartKind.manual,
    ];

/// Manual start point chosen by long-press on the map (or null).
class ManualStartNotifier extends Notifier<LatLng?> {
  @override
  LatLng? build() => null;
  void set(LatLng? point) => state = point;
  void clear() => state = null;
}

final manualStartProvider =
    NotifierProvider<ManualStartNotifier, LatLng?>(ManualStartNotifier.new);

/// Last known GPS fix (updated by the map screen's position stream).
class UserLocationNotifier extends Notifier<UserLocation?> {
  @override
  UserLocation? build() => null;
  void set(UserLocation? loc) => state = loc;
}

final userLocationProvider =
    NotifierProvider<UserLocationNotifier, UserLocation?>(
        UserLocationNotifier.new);

class StartPreferenceNotifier extends Notifier<StartPreference> {
  @override
  StartPreference build() => StartPreference.auto;
  void set(StartPreference p) => state = p;
}

final startPreferenceProvider =
    NotifierProvider<StartPreferenceNotifier, StartPreference>(
        StartPreferenceNotifier.new);
