import 'package:flutter/material.dart';

/// Mint & white palette (TZ, section 10).
abstract final class AppColors {
  static const background = Color(0xFFFFFFFF);
  static const surface = Color(0xFFF4FBF8);
  static const mint100 = Color(0xFFE3F6EE);
  static const mint300 = Color(0xFF9FE0C6);
  static const mint500 = Color(0xFF3EB489); // decor only, not for small text
  static const primary = Color(0xFF0E7A5A);
  static const border = Color(0xFFDCEFE7);
  static const text = Color(0xFF0F1F1A);
  static const textMuted = Color(0xFF4A5B55);

  // Accessibility status colors.
  static const ok = Color(0xFF0E7A5A);
  static const warn = Color(0xFF8A5A00);
  static const warnBg = Color(0xFFFFF4D6);
  static const bad = Color(0xFFB42318);
  static const badBg = Color(0xFFFDECEA);
  static const unknown = Color(0xFF5F6B76);
}
