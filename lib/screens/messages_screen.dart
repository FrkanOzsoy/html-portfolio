import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../data_repo.dart';
import '../models.dart';
import '../theme.dart';

const _uuid = Uuid();

/// Flat, single shared chat room for the store's staff -- matches the app's
/// single shared-account model, so there's nothing to scope separate
/// threads by. Requires internet (no offline queueing -- see data_repo.dart).
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  final _repo = DataRepo();
  final _bodyController = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription<List<ChatMessage>>? _sub;

  // Keyed by message id (client-generated at send time) so an optimistic
  // entry and its server-confirmed counterpart are the same row, not a
  // duplicate -- this is what makes a just-sent message show up instantly.
  final Map<String, ChatMessage> _byId = {};
  final Set<String> _pendingIds = {};
  String? _myName;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _repo.getStaffName().then((name) {
      if (mounted) setState(() => _myName = name);
    });
    _sub = _repo.watchMessages().listen((messages) {
      if (!mounted) return;
      setState(() {
        for (final m in messages) {
          _byId[m.id] = m;
          _pendingIds.remove(m.id);
        }
      });
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _bodyController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<ChatMessage> get _sortedMessages {
    final list = _byId.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final body = _bodyController.text.trim();
    if (body.isEmpty) return;

    final name = _myName ?? await _repo.getStaffName();
    if (name == null) return; // shouldn't happen -- login gate sets this first

    final id = _uuid.v4();
    final optimistic = ChatMessage(id: id, senderName: name, body: body, createdAt: DateTime.now());
    setState(() {
      _byId[id] = optimistic;
      _pendingIds.add(id);
      _sending = true;
    });
    _bodyController.clear();
    _scrollToBottom();

    try {
      await _repo.sendMessage(id, name, body);
    } catch (_) {
      if (mounted) {
        setState(() {
          _byId.remove(id);
          _pendingIds.remove(id);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mesaj gönderilemedi. İnternet bağlantınızı kontrol edin.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = _sortedMessages;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: messages.isEmpty
                  ? const Center(
                      child: Text('Henüz mesaj yok.', style: TextStyle(color: AppColors.brown500)),
                    )
                  : ListView.separated(
                      controller: _scrollController,
                      itemCount: messages.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) => _MessageBubble(
                        message: messages[i],
                        isMine: messages[i].senderName == _myName,
                        pending: _pendingIds.contains(messages[i].id),
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _bodyController,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(hintText: 'Mesaj yazın…', isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _send,
                  style: IconButton.styleFrom(backgroundColor: AppColors.terracotta),
                  icon: _sending
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send, color: Colors.white),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// A handful of distinguishable cool/jewel-tone hues, deliberately outside
// the app's warm brown/red/gold family (terracotta/olive/mustard/success
// already mean something specific elsewhere), picked deterministically per
// sender name so avatar color never coincidentally matches a status color.
const _senderPalette = [
  Color(0xFF4A6FA5), // blue
  Color(0xFF6B4E8E), // purple
  Color(0xFF3E8E9E), // teal
  Color(0xFFB0546A), // rose
  Color(0xFF4E5C8E), // indigo
  Color(0xFF9E6B8E), // mauve
  Color(0xFF7B6BA5), // lavender
  Color(0xFF5C8AA5), // sky blue
];

Color _colorForSender(String name) {
  final sum = name.codeUnits.fold<int>(0, (acc, c) => acc + c);
  return _senderPalette[sum % _senderPalette.length];
}

const _monthsTr = ['Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz', 'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara'];

/// Just the time for anything sent today; date + time otherwise, so old
/// messages remain unambiguous without cluttering today's conversation.
String _formatDateTime(DateTime utc) {
  final dt = utc.toLocal();
  final now = DateTime.now();
  final time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
  if (isToday) return time;
  return '${dt.day} ${_monthsTr[dt.month - 1]} $time';
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMine;
  final bool pending;

  const _MessageBubble({required this.message, required this.isMine, required this.pending});

  @override
  Widget build(BuildContext context) {
    final senderColor = _colorForSender(message.senderName);
    return AnimatedOpacity(
      opacity: pending ? 0.6 : 1,
      duration: const Duration(milliseconds: 200),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          // Capped at a fixed width, not a % of the window -- on a wide
          // desktop window, 75% of the width made even a two-word message
          // stretch into a huge, mostly-empty bubble.
          constraints: BoxConstraints(maxWidth: (MediaQuery.of(context).size.width * 0.75).clamp(0.0, 420.0)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isMine ? AppColors.terracotta.withValues(alpha: 0.14) : AppColors.creamCard,
            borderRadius: BorderRadius.circular(AppRadius.bubble),
            border: Border.all(color: isMine ? AppColors.terracotta.withValues(alpha: 0.4) : AppColors.creamBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isMine ? '${message.senderName} (Sen)' : message.senderName,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: senderColor),
              ),
              const SizedBox(height: 2),
              Text(
                message.body,
                style: const TextStyle(color: AppColors.brown900, fontSize: 14),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatDateTime(message.createdAt),
                    style: const TextStyle(fontSize: 10, color: AppColors.brown400),
                  ),
                  if (pending) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.schedule, size: 10, color: AppColors.brown400),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
