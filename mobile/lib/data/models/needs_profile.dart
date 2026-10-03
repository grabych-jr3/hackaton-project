enum ProfilePreset { wheelchair, stroller, custom }

/// User's thresholds (TZ, section 2). Stored only on the device;
/// no information about disability is collected.
class NeedsProfile {
  const NeedsProfile({
    required this.preset,
    required this.maxSteps,
    required this.maxKerbCm,
    required this.maxInclinePct,
    this.needsToilet = false,
    this.needsBenches = false,
    this.avoidCrowds = true,
  });

  static const wheelchair = NeedsProfile(
    preset: ProfilePreset.wheelchair,
    maxSteps: 0,
    maxKerbCm: 3,
    maxInclinePct: 6,
    needsToilet: true,
  );

  static const stroller = NeedsProfile(
    preset: ProfilePreset.stroller,
    maxSteps: 2,
    maxKerbCm: 6,
    maxInclinePct: 10,
  );

  final ProfilePreset preset;
  final int maxSteps;
  final int maxKerbCm;
  /// Averaged passage width for every wheelchair / stroller type. Not
  /// user-configurable.
  static const standardWidthCm = 75;

  int get minWidthCm => standardWidthCm;
  final int maxInclinePct;
  final bool needsToilet;
  final bool needsBenches;
  final bool avoidCrowds;

  NeedsProfile copyWith({
    ProfilePreset? preset,
    int? maxSteps,
    int? maxKerbCm,
    int? maxInclinePct,
    bool? needsToilet,
    bool? needsBenches,
    bool? avoidCrowds,
  }) {
    return NeedsProfile(
      preset: preset ?? this.preset,
      maxSteps: maxSteps ?? this.maxSteps,
      maxKerbCm: maxKerbCm ?? this.maxKerbCm,
      maxInclinePct: maxInclinePct ?? this.maxInclinePct,
      needsToilet: needsToilet ?? this.needsToilet,
      needsBenches: needsBenches ?? this.needsBenches,
      avoidCrowds: avoidCrowds ?? this.avoidCrowds,
    );
  }

  Map<String, dynamic> toJson() => {
        'preset': preset.name,
        'maxSteps': maxSteps,
        'maxKerbCm': maxKerbCm,
        'minWidthCm': minWidthCm,
        'maxInclinePct': maxInclinePct,
        'needsToilet': needsToilet,
        'needsBenches': needsBenches,
        'avoidCrowds': avoidCrowds,
      };

  factory NeedsProfile.fromJson(Map<String, dynamic> json) {
    return NeedsProfile(
      preset: ProfilePreset.values.byName(json['preset'] as String),
      maxSteps: json['maxSteps'] as int,
      maxKerbCm: json['maxKerbCm'] as int,
      // Stored 'minWidthCm' from older versions is ignored (always 75).
      maxInclinePct: json['maxInclinePct'] as int,
      needsToilet: json['needsToilet'] as bool? ?? false,
      needsBenches: json['needsBenches'] as bool? ?? false,
      avoidCrowds: json['avoidCrowds'] as bool? ?? true,
    );
  }
}
