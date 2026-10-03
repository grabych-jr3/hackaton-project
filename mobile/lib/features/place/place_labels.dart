import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/accessibility_fact.dart';
import '../../data/models/place.dart';
import '../../domain/profile_match.dart';

/// Polish UI texts, icons and colors for domain enums.

String formatDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

extension FeatureLabels on Feature {
  String get label => switch (this) {
        Feature.steps => 'Schody',
        Feature.kerbHeight => 'Krawężnik',
        Feature.doorWidth => 'Szerokość wejścia',
        Feature.incline => 'Nachylenie',
        Feature.ramp => 'Podjazd',
        Feature.elevator => 'Winda',
        Feature.toilet => 'Toaleta dostępna',
        Feature.bench => 'Miejsca do odpoczynku',
        Feature.disabledParking => 'Parking dla osób z niepełnosprawnością',
      };

  IconData get icon => switch (this) {
        Feature.steps => Icons.stairs_outlined,
        Feature.kerbHeight => Icons.straighten,
        Feature.doorWidth => Icons.door_front_door_outlined,
        Feature.incline => Icons.trending_up,
        Feature.ramp => Icons.accessible_forward,
        Feature.elevator => Icons.elevator_outlined,
        Feature.toilet => Icons.wc,
        Feature.bench => Icons.chair_outlined,
        Feature.disabledParking => Icons.local_parking,
      };

  bool get isBarrier => switch (this) {
        Feature.steps ||
        Feature.kerbHeight ||
        Feature.doorWidth ||
        Feature.incline =>
          true,
        _ => false,
      };

  String formatValue(Object value) {
    if (value is bool) return value ? 'Tak' : 'Nie';
    final unit = switch (this) {
      Feature.kerbHeight || Feature.doorWidth => ' cm',
      Feature.incline => '%',
      _ => '',
    };
    final text = value is String ? value.replaceAll('-', '–') : '$value';
    return '$text$unit';
  }
}

extension SourceLabels on DataSource {
  String get label => switch (this) {
        DataSource.osm => 'OpenStreetMap',
        DataSource.msip => 'MSIP Kraków',
        DataSource.otwarteDane => 'Otwarte Dane Kraków',
        DataSource.owner => 'Właściciel obiektu',
        DataSource.user => 'Zgłoszenie użytkownika',
        DataSource.ai => 'Analiza AI zdjęcia',
        DataSource.estimate => 'Szacunek',
      };
}

/// Visual style of a status: always icon + text, never color only (WCAG).
class StatusStyle {
  const StatusStyle(this.label, this.icon, this.color, this.background);

  final String label;
  final IconData icon;
  final Color color;
  final Color background;
}

extension TrustStyle on TrustLevel {
  StatusStyle get style => switch (this) {
        TrustLevel.confirmed => const StatusStyle(
            'Potwierdzone', Icons.verified_outlined, AppColors.ok, AppColors.mint100),
        TrustLevel.openData => const StatusStyle(
            'Dane otwarte', Icons.public, AppColors.primary, AppColors.surface),
        TrustLevel.reported => const StatusStyle('Niezweryfikowane',
            Icons.person_outline, AppColors.warn, AppColors.warnBg),
        TrustLevel.ai => const StatusStyle('AI · niezweryfikowane',
            Icons.smart_toy_outlined, AppColors.warn, AppColors.warnBg),
        TrustLevel.estimate => const StatusStyle(
            'Szacunek', Icons.calculate_outlined, AppColors.unknown, AppColors.surface),
        TrustLevel.conflicting => const StatusStyle(
            'Dane sprzeczne', Icons.warning_amber, AppColors.bad, AppColors.badBg),
        TrustLevel.outdated => const StatusStyle(
            'Nieaktualne', Icons.history, AppColors.unknown, AppColors.surface),
        TrustLevel.noData => const StatusStyle(
            'Brak danych', Icons.help_outline, AppColors.unknown, AppColors.surface),
      };
}

extension VerdictStyle on Verdict {
  StatusStyle get style => switch (this) {
        Verdict.suitable => const StatusStyle('Pasuje do Twoich potrzeb',
            Icons.check_circle_outline, AppColors.ok, AppColors.mint100),
        Verdict.partial => const StatusStyle('Częściowo pasuje',
            Icons.error_outline, AppColors.warn, AppColors.warnBg),
        Verdict.notSuitable => const StatusStyle(
            'Nie pasuje', Icons.block, AppColors.bad, AppColors.badBg),
        Verdict.insufficientData => const StatusStyle('Za mało danych',
            Icons.help_outline, AppColors.unknown, AppColors.surface),
      };
}

extension CheckStyle on CheckStatus {
  StatusStyle get style => switch (this) {
        CheckStatus.pass => const StatusStyle(
            'OK', Icons.check, AppColors.ok, AppColors.mint100),
        CheckStatus.borderline => const StatusStyle(
            'Na granicy', Icons.error_outline, AppColors.warn, AppColors.warnBg),
        CheckStatus.fail => const StatusStyle(
            'Bariera', Icons.close, AppColors.bad, AppColors.badBg),
        CheckStatus.unknown => const StatusStyle(
            'Brak danych', Icons.help_outline, AppColors.unknown, AppColors.surface),
      };
}

extension CategoryLabels on PlaceCategory {
  String get label => switch (this) {
        PlaceCategory.attraction => 'Atrakcja',
        PlaceCategory.museum => 'Muzeum',
        PlaceCategory.church => 'Kościół',
        PlaceCategory.cafe => 'Kawiarnia',
        PlaceCategory.restaurant => 'Restauracja',
        PlaceCategory.park => 'Park',
        PlaceCategory.bridge => 'Most / kładka',
      };

  IconData get icon => switch (this) {
        PlaceCategory.attraction => Icons.castle_outlined,
        PlaceCategory.museum => Icons.museum_outlined,
        PlaceCategory.church => Icons.church_outlined,
        PlaceCategory.cafe => Icons.local_cafe_outlined,
        PlaceCategory.restaurant => Icons.restaurant_outlined,
        PlaceCategory.park => Icons.park_outlined,
        PlaceCategory.bridge => Icons.directions_walk,
      };
}
