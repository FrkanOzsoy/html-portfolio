import 'package:flutter/material.dart';

/// Mirrors the color tokens from the original web app
/// (barkod-tarayici/src/app/globals.css) for visual continuity.
class AppColors {
  static const cream = Color(0xFFF7EDE0);
  static const creamCard = Color(0xFFFFFAF2);
  static const creamBorder = Color(0xFFE8D7BF);

  static const brown950 = Color(0xFF241610);
  static const brown900 = Color(0xFF2E1E14);
  static const brown800 = Color(0xFF40291A);
  static const brown700 = Color(0xFF5C3A22);
  static const brown600 = Color(0xFF79492A);
  static const brown500 = Color(0xFF96602F);
  static const brown400 = Color(0xFFB9885A);
  static const brown300 = Color(0xFFD4AC81);
  static const brown200 = Color(0xFFE6CCA4);
  static const brown100 = Color(0xFFF0DFC2);

  static const terracotta = Color(0xFFB5502F);
  static const olive = Color(0xFF6F6B2F);
  static const mustard = Color(0xFFA97A1F);
}

ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.cream,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.terracotta,
      primary: AppColors.terracotta,
      surface: AppColors.cream,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.brown900,
      foregroundColor: AppColors.brown100,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: AppColors.creamCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.creamBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.creamBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.creamBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.terracotta, width: 2),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.terracotta,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown900),
      bodyMedium: TextStyle(color: AppColors.brown700),
    ),
  );
}
