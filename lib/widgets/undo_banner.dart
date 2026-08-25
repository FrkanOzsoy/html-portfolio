import 'package:flutter/material.dart';
import '../theme.dart';

/// Content for an undo [SnackBar] -- a message and a "Geri Al" button
/// above a thin red bar that fills from empty to full over [duration],
/// giving a continuous visual sense of how much time is left instead of
/// the message just vanishing without warning. Deliberately not a
/// confirmation of the delete itself -- the delete already happened
/// instantly (this app is local-first); this is purely a grace-period
/// undo affordance.
class UndoBannerContent extends StatefulWidget {
  final String message;
  final VoidCallback onUndo;
  final Duration duration;

  const UndoBannerContent({
    super.key,
    required this.message,
    required this.onUndo,
    this.duration = const Duration(seconds: 4),
  });

  @override
  State<UndoBannerContent> createState() => _UndoBannerContentState();
}

class _UndoBannerContentState extends State<UndoBannerContent> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: widget.duration)..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(widget.message, style: const TextStyle(color: Colors.white), overflow: TextOverflow.ellipsis),
              ),
              TextButton(
                onPressed: widget.onUndo,
                child: const Text('Geri Al', style: TextStyle(color: AppColors.terracotta, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: _controller.value,
              child: Container(height: 3, color: AppColors.terracotta),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shows the undo banner as a floating [SnackBar]. Clears any snackbar
/// already showing first, so rapid successive deletes don't stack.
///
/// Takes the [ScaffoldMessengerState] directly rather than a [BuildContext]
/// so a caller that's about to navigate away (e.g. deleting a whole list,
/// which pops back to Listelerim) can grab it *before* popping and still
/// show the banner afterward -- a `BuildContext` from the popped route
/// would already be defunct by then.
void showUndoSnackBar(ScaffoldMessengerState messenger, {required String message, required VoidCallback onUndo}) {
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 4),
      backgroundColor: AppColors.brown900,
      behavior: SnackBarBehavior.floating,
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.box)),
      content: UndoBannerContent(
        message: message,
        onUndo: () {
          messenger.hideCurrentSnackBar();
          onUndo();
        },
      ),
    ),
  );
}
