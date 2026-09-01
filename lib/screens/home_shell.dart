import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_settings.dart';
import '../data_repo.dart';
import '../platform_util.dart';
import '../push_service.dart';
import '../sync_engine.dart';
import '../theme.dart';
import '../update_checker.dart';
import 'login_screen.dart';
import 'scanner_screen.dart';
import 'search_screen.dart';
import 'lists_screen.dart';
import 'bulk_price_import_screen.dart';
import 'kasaya_gonder_screen.dart';
import 'istatistik_screen.dart';
import 'messages_screen.dart';
import 'pending_ops_debug_screen.dart';
import 'product_create_screen.dart';
import 'settings_screen.dart';
import '../widgets/responsive_body.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  final _repo = DataRepo();
  StreamSubscription? _pendingChangesSub;
  StreamSubscription? _pendingCreatesSub;
  int _pendingChangesCount = 0;
  int _pendingCreatesCount = 0;
  int get _kasayaQueueCount => _pendingChangesCount + _pendingCreatesCount;
  DateTime? _lastUpdateCheck;

  // Canonical screen ids -- fixed regardless of platform. What changes
  // per-platform is the *display order* (see _tabOrder), so _index below is
  // always a position in that order, never one of these ids directly.
  static const _idScanner = 0;
  static const _idSearch = 1;
  static const _idLists = 2;
  static const _idGonder = 3;
  static const _idMessages = 4;
  // Desktop-only 6th destination -- on a phone "Teraziye Gönder" stays a
  // tab inside Kasaya Gönder (KasayaGonderScreen's own TabBar); the wide
  // desktop window has room to pull it out to its own top-menu entry.
  static const _idTerazi = 5;
  // Desktop-only -- pinned far right (see _desktopOrder).
  static const _idAyarlar = 6;
  // Desktop-only -- read-only reporting/analytics over the till's live sales
  // (INTER_BOS mirror): Son İşlemler, Günlük Özet, İptaller, Fiyat
  // Uyuşmazlığı, Z Raporları, Ölü Stok.
  static const _idIstatistik = 7;
  // Desktop: its own top-level section (after İstatistik). Mobile: Ramazan's
  // standalone replacement for İstatistik (he doesn't get the rest of
  // İstatistik at all, see _mobileOrderRamazan) -- Furkan/Ahmet instead see
  // it nested inside İstatistik itself (istatistik_screen.dart), not here.
  static const _idKasap = 8;
  // Desktop-only -- its own top-level section, same as _idKasap. Never
  // appears on mobile at all outside İstatistik's own nested tab.
  static const _idManav = 9;

  static const _titles = [
    'Tarayıcı', 'Ürün Ara', 'Listelerim', 'Kasaya Gönder', 'Mesajlar', 'Teraziye Gönder', 'Ayarlar', 'İstatistik',
    'Kasap', 'Manav',
  ];

  // Feeds both chrome styles below -- only how they're laid out (bottom
  // tabs vs. a top menu bar) differs. Indexed by screen id, so the Teraziye
  // entry is present here even though only _desktopOrder references it.
  static const _navIcons = [
    (icon: Icons.qr_code_scanner, label: 'Tarayıcı'),
    (icon: Icons.search, label: 'Ürün Ara'),
    (icon: Icons.list_alt, label: 'Listelerim'),
    (icon: Icons.point_of_sale_outlined, label: 'Gönder'),
    (icon: Icons.chat_bubble_outline, label: 'Mesajlar'),
    (icon: Icons.monitor_weight_outlined, label: 'Terazi'),
    (icon: Icons.settings_outlined, label: 'Ayarlar'),
    (icon: Icons.insights_outlined, label: 'İstatistik'),
    (icon: Icons.set_meal_outlined, label: 'Kasap'),
    (icon: Icons.eco_outlined, label: 'Manav'),
  ];

  // Desktop staff live in Ürün Ara most of the day (that's the whole point
  // of the Excel-style table there), so it opens first. Tarayıcı is dropped
  // entirely on desktop -- mobile_scanner (the camera/barcode plugin) has
  // no Windows implementation at all (checked its own pubspec: only
  // android/ios/macos/web are declared), so the tab could never actually
  // work there; a real store till reads barcodes through a physical
  // USB scanner typed straight into Ürün Ara anyway, not a webcam. Mobile
  // keeps the original order and the scanner (its primary workflow there).
  static const _desktopOrder = [
    _idSearch, _idLists, _idGonder, _idTerazi, _idMessages, _idIstatistik, _idKasap, _idManav, _idAyarlar,
  ];
  static const _mobileOrder = [_idScanner, _idSearch, _idLists, _idGonder, _idMessages, _idIstatistik];
  // Ramazan doesn't get İstatistik at all on mobile -- Kasap replaces it as
  // its own standalone destination in that same nav slot instead of living
  // nested inside İstatistik (see _isRamazan/_screenFor).
  static const _mobileOrderRamazan = [_idScanner, _idSearch, _idLists, _idGonder, _idMessages, _idKasap];
  List<int> get _tabOrder => _isDesktop ? _desktopOrder : (_isRamazan == true ? _mobileOrderRamazan : _mobileOrder);

  // Mobile-only; resolved once off the device's own staff name. null while
  // resolving -- build() shows a brief spinner rather than the wrong nav
  // (default first, correct second) which would visibly swap out from under
  // whichever tab position the user happens to be sitting on.
  bool? _isRamazan;

  // A phone or tablet gets the OS-native bottom tab bar; anything else
  // (Windows, and Linux/macOS if this is ever built for them) gets a
  // desktop-shaped top menu bar instead -- a bottom tab strip stretched
  // across a 1280px desktop window is what actually reads as "just the
  // mobile app running on a PC", not the window size itself.
  bool get _isDesktop => isDesktopPlatform;

  // Tab navigation history -- every tap or forward swipe is a genuine new
  // visit and gets pushed here. A "return" swipe (swipe right) pops this
  // stack instead of just stepping to index-1, so swiping back always lands
  // on the tab you actually came from, even if you jumped there directly
  // via the nav bar rather than swiping through the tabs in order. That pop
  // itself is not pushed back on -- it's undoing a visit, not making one.
  final List<int> _tabHistory = [];

  void _goToTab(int newIndex) {
    if (newIndex < 0 || newIndex >= _tabOrder.length || newIndex == _index) return;
    setState(() {
      _tabHistory.add(_index);
      if (_tabHistory.length > 20) _tabHistory.removeAt(0);
      _index = newIndex;
    });
  }

  void _swipeForward() {
    if (_index < _tabOrder.length - 1) _goToTab(_index + 1);
  }

  void _swipeReturn() {
    if (_tabHistory.isNotEmpty) {
      setState(() => _index = _tabHistory.removeLast());
    } else if (_index > 0) {
      setState(() => _index -= 1);
    }
  }

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      // Desktop honours the "Açılış Sekmesi" setting (Ayarlar tab); mobile
      // always starts on the scanner, its primary workflow.
      final pos = _tabOrder.indexOf(appSettings.defaultTabId);
      if (pos >= 0) _index = pos;
    } else {
      _repo.getStaffName().then((name) {
        if (!mounted) return;
        final n = name?.trim().toLowerCase();
        setState(() => _isRamazan = n == 'ramazan');
      });
    }
    // Idempotent -- safe whether we arrived here via a fresh sign-in or a
    // resumed session (main.dart skips straight to HomeShell for the latter).
    SyncEngine.instance.start();
    // Register this (signed-in) device for the nightly push -- the attempt in
    // main() runs before login and can't pass RLS.
    unawaited(PushService.instance.syncToken());
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
    _pendingChangesSub = _repo.watchAllPendingChanges().listen((entries) {
      if (mounted) setState(() => _pendingChangesCount = entries.length);
    });
    _pendingCreatesSub = _repo.watchAllPendingCreates().listen((entries) {
      if (mounted) setState(() => _pendingCreatesCount = entries.length);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pendingChangesSub?.cancel();
    _pendingCreatesSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // initState only runs on a true cold start -- bringing the app back
    // from the background (the common case once it's been open a while)
    // doesn't recreate this widget, so without this a stale install could
    // sit unprompted indefinitely even after a new version ships.
    if (state == AppLifecycleState.resumed) _checkForUpdate();
  }

  Future<void> _checkForUpdate() async {
    // `app_releases` (and its APK download URL) is Android-only -- there's
    // no automated Windows release row to compare against, so the version
    // check always saw a huge Android versionCode against Windows's own
    // tiny build number and offered an "update" that was really just the
    // Android APK. Skip this on desktop entirely until a real Windows
    // release pipeline exists.
    if (_isDesktop) return;
    // Avoid re-checking on every rapid resume (e.g. quickly switching apps).
    final now = DateTime.now();
    if (_lastUpdateCheck != null && now.difference(_lastUpdateCheck!) < const Duration(minutes: 1)) return;
    _lastUpdateCheck = now;

    final release = await UpdateChecker().checkForUpdate();
    if (release == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Yeni Sürüm: v${release.versionName}'),
        content: Text(
          release.changelog?.trim().isNotEmpty == true
              ? release.changelog!
              : 'Uygulamanın yeni bir sürümü mevcut.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Daha Sonra')),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await launchUrl(Uri.parse(release.downloadUrl), mode: LaunchMode.externalApplication);
            },
            child: const Text('Güncelle'),
          ),
        ],
      ),
    );
  }

  // `active` only matters to ScannerScreen (see its own doc comment for
  // why) -- every other screen ignores it, but it's simplest to thread
  // through the same call uniformly here.
  Widget _screenFor(int id, {required bool active}) => switch (id) {
        _idScanner => ScannerScreen(active: active),
        _idSearch => const SearchScreen(),
        _idLists => const ListsScreen(),
        _idGonder => const KasayaGonderScreen(),
        _idTerazi => const TeraziyeGonderScreen(),
        _idAyarlar => const SettingsScreen(),
        _idIstatistik => _isDesktop ? const IstatistikScreen() : const MobileIstatistikGate(),
        _idKasap => ScopedStatsBody(title: 'Kasap', barcodesResolver: DataRepo().getKasapBarcodes),
        _idManav => ScopedStatsBody(title: 'Manav', barcodesResolver: DataRepo().getManavBarcodes),
        _ => const MessagesScreen(),
      };

  Future<void> _signOut() async {
    await _repo.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = _isDesktop;
    if (!desktop && _isRamazan == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final order = _tabOrder;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('📦', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Flexible(child: Text(_titles[order[_index]], overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
            tooltip: 'Çıkış',
          ),
        ],
      ),
      body: Column(
        children: [
          if (desktop)
            _DesktopTopMenu(
              items: [for (final id in order) _navIcons[id]],
              selectedIndex: _index,
              pendingBadgeIndex: order.indexOf(_idGonder),
              pendingCount: _kasayaQueueCount,
              onSelected: _goToTab,
              // Digisoft gives "Stok Tanıtım Kartı" its own named, prominent
              // ribbon button rather than burying it in a menu -- a small
              // "+" icon inside Ürün Ara (still there as a quick shortcut)
              // doesn't read the same way. Both of these are genuinely
              // different from the four tabs beside them (a one-shot push,
              // not a persistent destination with its own tab state), so
              // they get their own distinct, accent-colored controls
              // instead of pretending to be extra tabs. Fiyat Listesi İçe
              // Aktar used to live as a button inside Kasaya Gönder itself
              // -- moved up here for the same reason as Yeni Ürün: it's an
              // action, not a place to browse.
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TopMenuActionButton(
                    icon: Icons.upload_file,
                    label: 'Fiyat Listesi İçe Aktar',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const BulkPriceImportScreen()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _TopMenuActionButton(
                    icon: Icons.add_circle_outline,
                    label: 'Yeni Ürün Oluştur',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ProductCreateScreen()),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          StreamBuilder<int>(
            stream: _repo.watchPendingOpsCount(),
            builder: (context, snapshot) {
              final count = snapshot.data ?? 0;
              if (count == 0) return const SizedBox.shrink();
              return InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PendingOpsDebugScreen()),
                ),
                child: Container(
                  width: double.infinity,
                  color: AppColors.mustard.withValues(alpha: 0.15),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.cloud_upload_outlined, size: 14, color: AppColors.mustard),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          count == 1
                              ? '1 değişiklik bu cihazdan gönderiliyor… (detay için dokunun)'
                              : '$count değişiklik bu cihazdan gönderiliyor… (detay için dokunun)',
                          style: const TextStyle(color: AppColors.mustard, fontWeight: FontWeight.w600, fontSize: 12),
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 16, color: AppColors.mustard),
                    ],
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              // Mouse-drag-to-switch-tabs isn't a real desktop convention
              // (and would misfire against text selection/scrolling) --
              // the top menu is the only way to switch tabs on desktop.
              onHorizontalDragEnd: desktop
                  ? null
                  : (details) {
                      final velocity = details.primaryVelocity ?? 0;
                      if (velocity < -250) {
                        _swipeForward();
                      } else if (velocity > 250) {
                        _swipeReturn();
                      }
                    },
              child: ResponsiveBody(
                // Wide enough that the Ürün Ara table (desktop-only, see
                // search_screen.dart) gets real room instead of being
                // squeezed back down toward a phone-card width.
                maxWidth: desktop ? 1500 : 640,
                child: IndexedStack(
                  index: _index,
                  children: [
                    for (final id in order) _screenFor(id, active: order[_index] == id),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: desktop
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _goToTab,
              backgroundColor: AppColors.brown900,
              indicatorColor: AppColors.terracotta,
              labelTextStyle: WidgetStateProperty.resolveWith(
                (states) => TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: states.contains(WidgetState.selected) ? Colors.white : AppColors.brown300,
                ),
              ),
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.qr_code_scanner, color: AppColors.brown300),
                  selectedIcon: Icon(Icons.qr_code_scanner, color: Colors.white),
                  label: 'Tarayıcı',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.search, color: AppColors.brown300),
                  selectedIcon: Icon(Icons.search, color: Colors.white),
                  label: 'Ürün Ara',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.list_alt, color: AppColors.brown300),
                  selectedIcon: Icon(Icons.list_alt, color: Colors.white),
                  label: 'Listelerim',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: _kasayaQueueCount > 0,
                    label: Text('$_kasayaQueueCount'),
                    child: const Icon(Icons.point_of_sale_outlined, color: AppColors.brown300),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: _kasayaQueueCount > 0,
                    label: Text('$_kasayaQueueCount'),
                    child: const Icon(Icons.point_of_sale, color: Colors.white),
                  ),
                  label: 'Gönder',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline, color: AppColors.brown300),
                  selectedIcon: Icon(Icons.chat_bubble, color: Colors.white),
                  label: 'Mesajlar',
                ),
                if (_isRamazan == true)
                  const NavigationDestination(
                    icon: Icon(Icons.set_meal_outlined, color: AppColors.brown300),
                    selectedIcon: Icon(Icons.set_meal, color: Colors.white),
                    label: 'Kasap',
                  )
                else
                  const NavigationDestination(
                    icon: Icon(Icons.insights_outlined, color: AppColors.brown300),
                    selectedIcon: Icon(Icons.insights, color: Colors.white),
                    label: 'İstatistik',
                  ),
              ],
            ),
    );
  }
}

/// Horizontal top nav bar used instead of the bottom tab strip when
/// [HomeShell] detects a desktop platform -- same five destinations, same
/// color language (brown900 bar, terracotta selected state), just laid out
/// the way a Windows app's navigation reads rather than a phone's.
class _DesktopTopMenu extends StatelessWidget {
  final List<({IconData icon, String label})> items;
  final int selectedIndex;
  /// Position within [items] of the "Gönder" destination -- the only one
  /// that ever carries a pending-count badge. Passed in rather than
  /// hardcoded since desktop reorders the tabs (see HomeShell._tabOrder).
  final int pendingBadgeIndex;
  final int pendingCount;
  final ValueChanged<int> onSelected;
  final Widget? trailing;

  const _DesktopTopMenu({
    required this.items,
    required this.selectedIndex,
    required this.pendingBadgeIndex,
    required this.pendingCount,
    required this.onSelected,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.brown900,
      child: LayoutBuilder(
        builder: (context, c) {
          final itemWidgets = [for (var i = 0; i < items.length; i++) _buildItem(context, i)];
          // The centered layout only works while there's room for the tabs
          // *and* the trailing action buttons. Below that, the whole bar
          // scrolls horizontally so tabs never get clipped behind the
          // buttons at a smaller (non-maximized) window size.
          const roomy = 1400.0;
          if (c.maxWidth >= roomy) {
            return Row(
              children: [
                Expanded(
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: itemWidgets),
                ),
                ?trailing,
              ],
            );
          }
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...itemWidgets,
                if (trailing != null) ...[const SizedBox(width: 20), trailing!, const SizedBox(width: 12)],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildItem(BuildContext context, int i) {
    final selected = i == selectedIndex;
    final item = items[i];
    final color = selected ? Colors.white : AppColors.brown300;
    Widget icon = Icon(item.icon, color: color, size: 20);
    // Only "Gönder" ever carries a badge -- same convention as the mobile
    // bottom nav's count-of-pending-changes indicator.
    if (i == pendingBadgeIndex && pendingCount > 0) {
      icon = Badge(label: Text('$pendingCount'), child: icon);
    }
    return InkWell(
      onTap: () => onSelected(i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? AppColors.terracotta : Colors.transparent, width: 3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 8),
            Text(item.label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// One accent-colored, named action button in the top bar's trailing
/// slot -- shared by "Fiyat Listesi İçe Aktar" and "Yeni Ürün Oluştur" so
/// both read as the same kind of control (a one-shot action, not a tab).
class _TopMenuActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _TopMenuActionButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: AppColors.terracotta, borderRadius: BorderRadius.circular(AppRadius.chip)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
