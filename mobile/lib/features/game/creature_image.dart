import 'package:flutter/material.dart';

/// Species that have artwork in `assets/creatures/<id>.png`.
const _speciesWithArt = {
  'golab', 'jez', 'lis', 'sowa', 'wydra', 'bocian', 'niedzwiedz', 'smok',
  'jaszczur', 'plaszczka',
};

/// Creature artwork for [speciesId]; falls back to [emoji] when there is no image.
class CreatureImage extends StatelessWidget {
  const CreatureImage({
    super.key,
    required this.speciesId,
    required this.emoji,
    required this.size,
  });

  final String? speciesId;
  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = SizedBox.square(
      dimension: size,
      child: Center(
        child: Text(emoji, style: TextStyle(fontSize: size * 0.8, height: 1)),
      ),
    );
    if (!_speciesWithArt.contains(speciesId)) return fallback;
    return Image.asset(
      'assets/creatures/$speciesId.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}
