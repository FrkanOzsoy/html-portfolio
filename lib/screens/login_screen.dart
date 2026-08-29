import 'dart:async';
import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../platform_util.dart';
import '../theme.dart';
import 'home_shell.dart';

/// The fixed staff list mobile devices pick from at first login (instead of
/// typing a name). Still one shared auth account -- this only sets the local
/// display name used for chat / the activity log. Desktop keeps free text.
const kStaffProfiles = ['Ahmet', 'Osman', 'Ramazan', 'Furkan', 'Çoban'];

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _repo = DataRepo();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _repo.signIn(_passwordController.text);
      if (!mounted) return;

      final existingName = await _repo.getStaffName();
      if (existingName == null) {
        final name = isDesktopPlatform ? await _promptForName() : await _promptForProfile();
        if (name == null) {
          // User backed out of the name prompt -- stay on the login screen
          // rather than entering the app with no identity for chat/logs.
          await _repo.signOut();
          return;
        }
        await _repo.setStaffName(name);
      }

      unawaited(_repo.logAction('giris_yapildi'));
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeShell()),
      );
    } catch (_) {
      setState(() => _error = 'Şifre yanlış, tekrar deneyin.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Mobile, first login only: pick one of the fixed staff profiles. Same
  /// role as [_promptForName] on desktop -- sets the local display name.
  Future<String?> _promptForProfile() async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Kim kullanıyor?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in kStaffProfiles)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(p),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: const BorderSide(color: AppColors.brown300, width: 1.5),
                      alignment: Alignment.centerLeft,
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 15,
                          backgroundColor: AppColors.terracotta.withValues(alpha: 0.15),
                          child: Text(p.characters.first,
                              style: const TextStyle(color: AppColors.terracotta, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 12),
                        Text(p, style: const TextStyle(fontSize: 16, color: AppColors.brown900, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Vazgeç')),
        ],
      ),
    );
  }

  /// First login only: staff pick a display name, used for in-app messaging
  /// and the server-side activity log. Not cancelable by tapping outside --
  /// only the explicit "Vazgeç" button backs out (and signs back out).
  Future<String?> _promptForName() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('İsminiz'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Örn: Ahmet'),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.of(context).pop(v.trim());
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Vazgeç')),
          TextButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isNotEmpty) Navigator.of(context).pop(v);
            },
            child: const Text('Devam'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.brown950,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AppColors.terracotta.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(AppRadius.box),
                      border: Border.all(color: AppColors.terracotta.withValues(alpha: 0.4)),
                    ),
                    child: const Center(child: Text('📦', style: TextStyle(fontSize: 24))),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'ÇÇM-Barkod Okuyucu',
                    style: TextStyle(
                      color: AppColors.cream,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.brown900.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(AppRadius.box),
                      border: Border.all(color: AppColors.brown700),
                    ),
                    child: Column(
                      children: [
                        if (_error != null) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.terracotta.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(AppRadius.box),
                            ),
                            child: Text(_error!, style: const TextStyle(color: Colors.white)),
                          ),
                          const SizedBox(height: 16),
                        ],
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          autofocus: true,
                          style: const TextStyle(color: AppColors.cream),
                          decoration: InputDecoration(
                            labelText: 'Şifre',
                            labelStyle: const TextStyle(color: AppColors.brown300),
                            prefixIcon: const Icon(Icons.lock_outline, color: AppColors.brown400),
                            filled: true,
                            fillColor: AppColors.brown950.withValues(alpha: 0.6),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(AppRadius.box),
                              borderSide: const BorderSide(color: AppColors.brown700),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(AppRadius.box),
                              borderSide: const BorderSide(color: AppColors.terracotta, width: 2),
                            ),
                          ),
                          onSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('Giriş Yap'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
