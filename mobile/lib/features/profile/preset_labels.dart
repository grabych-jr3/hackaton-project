import 'package:flutter/material.dart';

import '../../data/models/needs_profile.dart';

extension PresetLabels on ProfilePreset {
  String get label => switch (this) {
        ProfilePreset.wheelchair => 'Wózek inwalidzki',
        ProfilePreset.stroller => 'Wózek dziecięcy',
        ProfilePreset.custom => 'Własne ustawienia',
      };

  String get shortLabel => switch (this) {
        ProfilePreset.wheelchair => 'Inwalidzki',
        ProfilePreset.stroller => 'Dziecięcy',
        ProfilePreset.custom => 'Własne',
      };

  String get description => switch (this) {
        ProfilePreset.wheelchair =>
          'Bez schodów, krawężnik do 3 cm, przejście min. 80 cm, dostępna toaleta',
        ProfilePreset.stroller =>
          'Do 2 stopni, krawężnik do 6 cm, przejście min. 60 cm',
        ProfilePreset.custom => 'Sam ustawisz progi dla barier',
      };

  IconData get icon => switch (this) {
        ProfilePreset.wheelchair => Icons.accessible,
        ProfilePreset.stroller => Icons.child_friendly,
        ProfilePreset.custom => Icons.tune,
      };

  NeedsProfile get defaults => switch (this) {
        ProfilePreset.wheelchair => NeedsProfile.wheelchair,
        ProfilePreset.stroller => NeedsProfile.stroller,
        ProfilePreset.custom =>
          NeedsProfile.wheelchair.copyWith(preset: ProfilePreset.custom),
      };
}
