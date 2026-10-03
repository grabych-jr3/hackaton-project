import 'package:flutter/material.dart';

/// Modern dark obsidian & neon emerald/mint palette.
abstract final class AppColors {
  // Base backgrounds & surfaces
  static const background = Color(0xFF090D12);
  static const surface = Color(0xFF131B24);
  static const surfaceElevated = Color(0xFF1B2430);
  static const surfaceGlass = Color(0xEB131B24);
  static const border = Color(0xFF223040);
  static const borderHighlight = Color(0xFF2E4156);

  // Mint & Emerald neon accents
  static const primary = Color(0xFF00E599);
  static const primaryBright = Color(0xFF34FFA9);
  static const primaryDark = Color(0xFF0E7A5A);
  static const primaryGlow = Color(0x3300E599);
  static const mint100 = Color(0xFF0E2A1F);
  static const mint300 = Color(0xFF1A5640);
  static const mint500 = Color(0xFF00E599);

  // High-tech secondary accents
  static const accentCyan = Color(0xFF00D2FF);
  static const accentPurple = Color(0xFF8B5CF6);
  static const gold = Color(0xFFFFD166);

  // Typography
  static const text = Color(0xFFF1F5F9);
  static const textMuted = Color(0xFF94A3B8);
  static const textDim = Color(0xFF64748B);

  // Accessibility status colors
  static const ok = Color(0xFF00E599);
  static const okBg = Color(0xFF0D281E);
  static const warn = Color(0xFFFFB800);
  static const warnBg = Color(0xFF332500);
  static const bad = Color(0xFFFF453A);
  static const badBg = Color(0xFF38100E);
  static const unknown = Color(0xFF8E9BB0); // >= 4.5:1 on background (WCAG AA)
  static const unknownBg = Color(0xFF1E293B);
}
