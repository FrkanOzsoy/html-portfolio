import 'dart:async';
import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../theme.dart';

/// Small colored-dot banner showing whether the till-PC sync service is
/// reachable right now, refreshed periodically. Used anywhere staff are
/// about to submit a write that needs that service alive to actually reach
/// Digisoft/kasa (product editor, Kasaya Gönder).
class SyncHealthBanner extends StatefulWidget {
  const SyncHealthBanner({super.key});

  @override
  State<SyncHealthBanner> createState() => _SyncHealthBannerState();
}

class _SyncHealthBannerState extends State<SyncHealthBanner> {
  final _repo = DataRepo();
  bool? _healthy;
  DateTime? _lastSeen;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final results = await Future.wait([_repo.isSyncHealthy(), _repo.getSyncHeartbeat()]);
    if (mounted) {
      setState(() {
        _healthy = results[0] as bool;
        _lastSeen = results[1] as DateTime?;
      });
    }
  }

  // "az önce" / "3 dk önce" / "2 sa önce" -- not a full timestamp, since
  // what matters here is "is this stale", not the exact clock time.
  String _relativeLastSeen(DateTime at) {
    final diff = DateTime.now().toUtc().difference(at.toUtc());
    if (diff.inSeconds < 30) return 'az önce';
    if (diff.inMinutes < 1) return '${diff.inSeconds} sn önce';
    if (diff.inHours < 1) return '${diff.inMinutes} dk önce';
    if (diff.inDays < 1) return '${diff.inHours} sa önce';
    return '${diff.inDays} gün önce';
  }

  @override
  Widget build(BuildContext context) {
    final ok = _healthy;
    final lastSeen = _lastSeen;
    final Color color;
    final String text;
    if (ok == null) {
      color = AppColors.brown300;
      text = 'Senkron durumu kontrol ediliyor…';
    } else if (ok) {
      color = AppColors.success;
      text = lastSeen == null ? 'Senkron aktif' : 'Senkron aktif — son görülme: ${_relativeLastSeen(lastSeen)}';
    } else {
      color = AppColors.terracotta;
      text = lastSeen == null
          ? 'Senkron şu an çalışmıyor — güncellemeler gecikebilir'
          : 'Senkron şu an çalışmıyor (son görülme: ${_relativeLastSeen(lastSeen)}) — güncellemeler gecikebilir';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(AppRadius.box)),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
        ],
      ),
    );
  }
}
