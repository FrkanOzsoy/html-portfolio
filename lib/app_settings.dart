import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-device UI preferences, set from the desktop "Ayarlar" tab
/// (settings_screen.dart). Stored in SharedPreferences -- these are cosmetic
/// per-machine choices, not shared staff data, so they never go to Supabase.
///
/// A single global [appSettings] instance is loaded once in main() before
/// runApp; screens that react to a setting listen to it (it's a
/// [ChangeNotifier]) via AnimatedBuilder/ListenableBuilder.
enum AppDensity { comfortable, compact }

class AppSettingsController extends ChangeNotifier {
  AppDensity _density = AppDensity.comfortable;
  double _textScale = 1.0;
  int _defaultTabId = 1; // matches HomeShell._idSearch
  int _tablePageSize = 100;

  AppDensity get density => _density;
  bool get compact => _density == AppDensity.compact;
  double get textScale => _textScale;
  int get defaultTabId => _defaultTabId;

  /// Rows per page in the big product tables (Ürün Ara, Ürün Satışları)
  /// before a pager kicks in. Persisted per device.
  int get tablePageSize => _tablePageSize;

  /// Extra vertical padding knocked off dense desktop table/list rows when
  /// "Sıkışık" is picked -- keeps one place deciding the delta.
  double get rowVerticalPadding => _density == AppDensity.compact ? 4 : 9;

  static const _kDensity = 'ui_density';
  static const _kTextScale = 'ui_text_scale';
  static const _kDefaultTab = 'ui_default_tab';
  static const _kTablePageSize = 'ui_table_page_size';

  static const textScaleOptions = <({String label, double value})>[
    (label: 'Küçük', value: 0.9),
    (label: 'Normal', value: 1.0),
    (label: 'Büyük', value: 1.15),
    (label: 'Çok Büyük', value: 1.3),
  ];

  static const tablePageSizeOptions = <int>[50, 100, 200, 500];

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _density = p.getString(_kDensity) == 'compact' ? AppDensity.compact : AppDensity.comfortable;
      _textScale = p.getDouble(_kTextScale) ?? 1.0;
      _defaultTabId = p.getInt(_kDefaultTab) ?? 1;
      _tablePageSize = p.getInt(_kTablePageSize) ?? 100;
      if (_tablePageSize < 10) _tablePageSize = 100;
    } catch (_) {
      // First run / unreadable prefs -- defaults stand.
    }
    notifyListeners();
  }

  Future<void> setDensity(AppDensity d) async {
    if (d == _density) return;
    _density = d;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDensity, d == AppDensity.compact ? 'compact' : 'comfortable');
  }

  Future<void> setTextScale(double s) async {
    if (s == _textScale) return;
    _textScale = s;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kTextScale, s);
  }

  Future<void> setDefaultTabId(int id) async {
    if (id == _defaultTabId) return;
    _defaultTabId = id;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kDefaultTab, id);
  }

  Future<void> setTablePageSize(int n) async {
    if (n == _tablePageSize || n < 10) return;
    _tablePageSize = n;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kTablePageSize, n);
  }
}

final appSettings = AppSettingsController();
