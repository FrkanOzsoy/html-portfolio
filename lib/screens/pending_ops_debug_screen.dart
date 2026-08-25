import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../sync_engine.dart';
import '../theme.dart';

/// Reached by tapping the "N değişiklik bu cihazdan gönderiliyor…" banner.
/// The queue itself is local-only (never uploaded, by definition -- it's
/// the outbox), so there was previously no way to tell *why* a backlog was
/// stuck without physically pulling the device's SQLite file. This lists
/// what's actually queued and shows the oldest op's last known failure
/// (see SyncEngine.lastFlushError), since that's the one op actually
/// blocking everything behind it -- flushPendingOps preserves order by
/// stopping at the first failure.
class PendingOpsDebugScreen extends StatefulWidget {
  const PendingOpsDebugScreen({super.key});

  @override
  State<PendingOpsDebugScreen> createState() => _PendingOpsDebugScreenState();
}

class _PendingOpsDebugScreenState extends State<PendingOpsDebugScreen> {
  final _repo = DataRepo();
  List<Map<String, Object?>> _ops = [];
  bool _loading = true;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final ops = await _repo.getPendingOpsDebugInfo();
    if (mounted) setState(() { _ops = ops; _loading = false; });
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    await SyncEngine.instance.pushNow();
    await _load();
    if (mounted) setState(() => _syncing = false);
  }

  String _summarize(String kind, Map<String, dynamic> payload) {
    final barcode = payload['barcode'] as String?;
    switch (kind) {
      case 'create_list':
        return 'Liste oluştur: ${payload['name']}';
      case 'delete_list':
        return 'Liste sil: ${payload['id']}';
      case 'add_item':
        return 'Listeye ekle: ${barcode ?? payload['id']}';
      case 'update_item':
        return 'Liste öğesi güncelle: ${payload['field']} (${payload['id']})';
      case 'delete_item':
        return 'Liste öğesi sil: ${payload['id']}';
      case 'stage_change':
        return 'Değişiklik öner: $barcode.${payload['field']} -> ${payload['new_value']}';
      case 'unstage_change':
        return 'Öneriyi iptal et: ${payload['id']}';
      case 'log_action':
        return 'Kayıt: ${payload['action']}';
      default:
        return kind;
    }
  }

  @override
  Widget build(BuildContext context) {
    final grouped = <String, int>{};
    for (final op in _ops) {
      final kind = op['kind'] as String;
      grouped[kind] = (grouped[kind] ?? 0) + 1;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Gönderilmeyi Bekleyen Değişiklikler')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${_ops.length} işlem bu cihazda henüz sunucuya ulaşmadı.',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.brown900),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      grouped.entries.map((e) => '${e.key}: ${e.value}').join(' · '),
                      style: const TextStyle(color: AppColors.brown500, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    ValueListenableBuilder(
                      valueListenable: SyncEngine.instance.lastFlushError,
                      builder: (context, error, _) {
                        if (error == null) return const SizedBox.shrink();
                        return Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: AppColors.terracotta.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(AppRadius.box),
                            border: Border.all(color: AppColors.terracotta),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'En eski işlem takılı kaldı (${error.kind}):',
                                style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.terracotta, fontSize: 13),
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                error.error,
                                style: const TextStyle(color: AppColors.terracotta, fontSize: 12, fontFamily: 'monospace'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    Expanded(
                      child: _ops.isEmpty
                          ? const Center(
                              child: Text('Bekleyen işlem yok.', style: TextStyle(color: AppColors.brown500)),
                            )
                          : ListView.separated(
                              itemCount: _ops.length,
                              separatorBuilder: (_, _) => const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final op = _ops[i];
                                final kind = op['kind'] as String;
                                Map<String, dynamic> payload;
                                try {
                                  payload = jsonDecode(op['payload'] as String) as Map<String, dynamic>;
                                } catch (_) {
                                  payload = {};
                                }
                                return ListTile(
                                  dense: true,
                                  leading: Text('#${op['id']}', style: const TextStyle(color: AppColors.brown400, fontSize: 11)),
                                  title: Text(_summarize(kind, payload), style: const TextStyle(fontSize: 13)),
                                  subtitle: Text(
                                    op['created_at'] as String? ?? '',
                                    style: const TextStyle(fontSize: 11, color: AppColors.brown400),
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _syncing ? null : _syncNow,
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.brown800),
                      icon: _syncing
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.sync),
                      label: const Text('Şimdi Gönder'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
