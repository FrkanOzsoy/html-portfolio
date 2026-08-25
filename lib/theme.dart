import 'package:flutter/material.dart';
import 'models.dart';

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

  /// The one "success / done" green used everywhere a request actually
  /// completed on the server (send confirmations, sync status, print
  /// status) -- distinct from [olive], which means something else
  /// (the "yeniden stoklama" list-type accent).
  static const success = Color(0xFF3D7A42);
}

/// Shared corner-radius scale -- "boxy, just a little rounded" rather than
/// pill/very-round, used consistently for buttons, cards, and badges. Modal
/// bottom sheets keep their own larger top-corner convention ([sheet]),
/// that's a distinct pattern, not part of this scale.
class AppRadius {
  /// Small inline badges/pills/chips.
  static const chip = 8.0;
  /// The standard radius for buttons, cards, and action containers.
  static const box = 10.0;
  /// Chat bubbles -- deliberately rounder than [box], a distinct convention.
  static const bubble = 14.0;
  /// Bottom sheet top corners.
  static const sheet = 20.0;
}

/// One shared color per list type -- used for its badge chip everywhere a
/// list type is shown (lists_screen, add_to_list_button's picker sheet), so
/// the two can't silently drift apart.
extension ListKindColorX on ListKind {
  Color get accentColor => switch (this) {
        ListKind.priceCheck => AppColors.terracotta,
        ListKind.restock => AppColors.olive,
        ListKind.priceChange => AppColors.mustard,
        ListKind.custom => AppColors.brown500,
      };
}

/// [desktop] scales up default control sizing (button padding, input field
/// height, base text) app-wide -- anywhere a button/field relies on this
/// theme's defaults rather than setting its own explicit size picks this up
/// for free, so it's not just the couple of screens that got hand-tuned
/// layouts (scanner, Ürün Ara, Listelerim). Buttons/fields that already set
/// their own padding inline are unaffected (widget-level style wins over
/// the theme default), same as on mobile.
ThemeData buildAppTheme({bool desktop = false}) {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.cream,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.terracotta,
      primary: AppColors.terracotta,
      surface: AppColors.cream,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.brown900,
      foregroundColor: AppColors.brown100,
      elevation: 0,
      toolbarHeight: desktop ? 64 : kToolbarHeight,
      titleTextStyle: TextStyle(color: AppColors.brown100, fontSize: desktop ? 20 : 18, fontWeight: FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      color: AppColors.creamCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.box),
        side: const BorderSide(color: AppColors.creamBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: desktop ? const EdgeInsets.symmetric(horizontal: 16, vertical: 20) : null,
      labelStyle: desktop ? const TextStyle(fontSize: 15) : null,
      hintStyle: desktop ? const TextStyle(fontSize: 15) : null,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.box),
        borderSide: const BorderSide(color: AppColors.creamBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.box),
        borderSide: const BorderSide(color: AppColors.creamBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.box),
        borderSide: const BorderSide(color: AppColors.terracotta, width: 2),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.terracotta,
        foregroundColor: Colors.white,
        padding: EdgeInsets.symmetric(vertical: desktop ? 18 : 14, horizontal: desktop ? 20 : 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.box)),
        textStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: desktop ? 16 : 14),
      ),
    ),
    textTheme: TextTheme(
      titleLarge: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.brown900),
      bodyMedium: TextStyle(color: AppColors.brown700, fontSize: desktop ? 15 : 14),
    ),
  );
}
