import 'package:flutter/material.dart';
import '../app_settings.dart';
import '../data_repo.dart';
import '../models.dart';
import '../theme.dart';

/// Desktop-only "Ayarlar" tab (HomeShell._idAyarlar, far right). Two parts:
/// per-device look-and-feel customization (each with a live preview so you
/// can see the change before committing to it), and a read-only İşlem
/// Geçmişi feed of every logged staff action.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _repo = DataRepo();
  late Future<List<ActivityEntry>> _logFuture = _repo.getActivityLog();

  void _reloadLog() => setState(() => _logFuture = _repo.getActivityLog());

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          const _SectionTitle('Kişiselleştirme', icon: Icons.tune),
          const SizedBox(height: 4),
          const Text(
            'Bu ayarlar yalnızca bu bilgisayarı etkiler.',
            style: TextStyle(color: AppColors.brown500, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          const _DensitySetting(),
          const SizedBox(height: 14),
          const _TextScaleSetting(),
          const SizedBox(height: 14),
          const _DefaultTabSetting(),
          const SizedBox(height: 32),
          Row(
            children: [
              const Expanded(child: _SectionTitle('İşlem Geçmişi', icon: Icons.history)),
              IconButton(
                onPressed: _reloadLog,
                icon: const Icon(Icons.refresh, color: AppColors.brown600),
                tooltip: 'Yenile',
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Kim, ne zaman, ne yaptı -- tüm cihazlardaki kayıtlı işlemler.',
            style: TextStyle(color: AppColors.brown500, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<ActivityEntry>>(
            future: _logFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final entries = snapshot.data ?? [];
              if (entries.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Text('Kayıt bulunamadı (çevrimdışı olabilirsiniz).',
                        style: TextStyle(color: AppColors.brown500)),
                  ),
                );
              }
              return _ActivityLogTable(entries: entries);
            },
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final IconData icon;
  const _SectionTitle(this.text, {required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.brown700),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppColors.brown900)),
      ],
    );
  }
}

/// Shared frame for one customization: a title, a short "what it does"
/// line, the control, and a live preview panel on the right.
class _SettingCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget control;
  final Widget preview;
  const _SettingCard({
    required this.title,
    required this.subtitle,
    required this.control,
    required this.preview,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(AppRadius.box),
        border: Border.all(color: AppColors.creamBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.brown900)),
                const SizedBox(height: 3),
                Text(subtitle, style: const TextStyle(color: AppColors.brown500, fontSize: 12.5, height: 1.35)),
                const SizedBox(height: 12),
                control,
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            flex: 2,
            child: Container(
              height: 118,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.cream,
                borderRadius: BorderRadius.circular(AppRadius.box),
                border: Border.all(color: AppColors.creamBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Önizleme', style: TextStyle(fontSize: 10, color: AppColors.brown400, letterSpacing: 0.5)),
                  const SizedBox(height: 6),
                  Expanded(child: preview),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChoiceChips<T> extends StatelessWidget {
  final List<({T value, String label})> options;
  final T selected;
  final ValueChanged<T> onSelected;
  const _ChoiceChips({required this.options, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in options)
          ChoiceChip(
            label: Text(o.label),
            selected: o.value == selected,
            onSelected: (_) => onSelected(o.value),
            selectedColor: AppColors.terracotta,
            labelStyle: TextStyle(
              color: o.value == selected ? Colors.white : AppColors.brown700,
              fontWeight: FontWeight.w600,
            ),
            backgroundColor: AppColors.brown100,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.chip)),
          ),
      ],
    );
  }
}

// ---- density ----

class _DensitySetting extends StatelessWidget {
  const _DensitySetting();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appSettings,
        builder: (context, _) => _buildCard(),
      );

  Widget _buildCard() {
    final compact = appSettings.compact;
    return _SettingCard(
      title: 'Yoğunluk',
      subtitle: 'Liste ve tablolarda satırların ne kadar sıkışık görüneceği. '
          '"Sıkışık" daha çok ürünü aynı anda gösterir.',
      control: _ChoiceChips<AppDensity>(
        options: const [
          (value: AppDensity.comfortable, label: 'Rahat'),
          (value: AppDensity.compact, label: 'Sıkışık'),
        ],
        selected: appSettings.density,
        onSelected: appSettings.setDensity,
      ),
      preview: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 3; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              margin: EdgeInsets.symmetric(vertical: compact ? 1.5 : 4),
              height: compact ? 12 : 18,
              decoration: BoxDecoration(
                color: AppColors.creamCard,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppColors.creamBorder),
              ),
            ),
        ],
      ),
    );
  }
}

// ---- text scale ----

class _TextScaleSetting extends StatelessWidget {
  const _TextScaleSetting();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appSettings,
        builder: (context, _) => _buildCard(),
      );

  Widget _buildCard() {
    return _SettingCard(
      title: 'Yazı Boyutu',
      subtitle: 'Uygulamadaki tüm yazıların büyüklüğü. Kasadan uzaktan bakılıyorsa büyütün.',
      control: _ChoiceChips<double>(
        options: [
          for (final o in AppSettingsController.textScaleOptions) (value: o.value, label: o.label),
        ],
        selected: appSettings.textScale,
        onSelected: appSettings.setTextScale,
      ),
      preview: Center(
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 200),
          style: TextStyle(
            fontSize: 13 * appSettings.textScale,
            color: AppColors.brown800,
            fontWeight: FontWeight.w600,
          ),
          child: const Text('Örnek: DEREOTU  25,00 ₺'),
        ),
      ),
    );
  }
}

// ---- default tab ----

class _DefaultTabSetting extends StatelessWidget {
  const _DefaultTabSetting();

  // id -> (label, icon); ids match HomeShell's canonical screen ids.
  static const _tabs = <({int id, String label, IconData icon})>[
    (id: 1, label: 'Ürün Ara', icon: Icons.search),
    (id: 2, label: 'Listelerim', icon: Icons.list_alt),
    (id: 3, label: 'Kasaya Gönder', icon: Icons.point_of_sale_outlined),
    (id: 7, label: 'Kasa', icon: Icons.receipt_long_outlined),
    (id: 5, label: 'Teraziye Gönder', icon: Icons.monitor_weight_outlined),
    (id: 4, label: 'Mesajlar', icon: Icons.chat_bubble_outline),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: appSettings,
        builder: (context, _) => _buildCard(),
      );

  Widget _buildCard() {
    final current = appSettings.defaultTabId;
    return _SettingCard(
      title: 'Açılış Sekmesi',
      subtitle: 'Uygulama açıldığında hangi sekmenin görüneceği. '
          'Bir sonraki açılışta geçerli olur.',
      control: DropdownButtonFormField<int>(
        initialValue: _tabs.any((t) => t.id == current) ? current : 1,
        isExpanded: true,
        decoration: const InputDecoration(isDense: true),
        items: [
          for (final t in _tabs)
            DropdownMenuItem(
              value: t.id,
              child: Row(
                children: [
                  Icon(t.icon, size: 16, color: AppColors.brown600),
                  const SizedBox(width: 8),
                  Text(t.label),
                ],
              ),
            ),
        ],
        onChanged: (id) {
          if (id != null) appSettings.setDefaultTabId(id);
        },
      ),
      preview: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final t in _tabs)
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.symmetric(vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: t.id == current ? AppColors.terracotta : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(t.icon,
                      size: 11, color: t.id == current ? Colors.white : AppColors.brown400),
                  const SizedBox(width: 5),
                  Text(
                    t.label,
                    style: TextStyle(
                      fontSize: 9.5,
                      color: t.id == current ? Colors.white : AppColors.brown400,
                      fontWeight: t.id == current ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---- activity log ----

class _ActivityLogTable extends StatelessWidget {
  final List<ActivityEntry> entries;
  const _ActivityLogTable({required this.entries});

  static String _fmt(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.${l.year}  ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.creamBorder),
        borderRadius: BorderRadius.circular(AppRadius.box),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            color: AppColors.brown100,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: const Row(
              children: [
                SizedBox(width: 150, child: _HCell('Tarih')),
                SizedBox(width: 120, child: _HCell('Kişi')),
                Expanded(flex: 2, child: _HCell('İşlem')),
                Expanded(flex: 3, child: _HCell('Ayrıntı')),
              ],
            ),
          ),
          for (var i = 0; i < entries.length; i++)
            Container(
              color: i.isEven ? Colors.white : AppColors.creamCard,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(_fmt(entries[i].at),
                        style: const TextStyle(fontSize: 12, color: AppColors.brown600)),
                  ),
                  SizedBox(
                    width: 120,
                    child: Text(entries[i].userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.brown800)),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(entries[i].label, style: const TextStyle(fontSize: 12.5, color: AppColors.brown900)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      entries[i].detail ?? '-',
                      style: const TextStyle(fontSize: 12, color: AppColors.brown500),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HCell extends StatelessWidget {
  final String text;
  const _HCell(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppColors.brown800));
}
