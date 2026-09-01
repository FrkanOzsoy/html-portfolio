import 'package:flutter/material.dart';
import '../theme.dart';

/// The two little wordless diagrams shown in the "Dosya tipi" picker, so a
/// user can recognise which shape their file is without reading anything:
///
/// * [ImportLayoutMockup.normal] -- a plain gridded table (header row + data
///   rows), the shape the normal import already handles.
/// * [ImportLayoutMockup.catalog] -- rows of photo cards, each with an image
///   and a few lines of fields underneath ("resimli kutucuklu").
class ImportLayoutMockup extends StatelessWidget {
  const ImportLayoutMockup._(this._catalog, {super.key});

  const ImportLayoutMockup.normal({Key? key}) : this._(false, key: key);
  const ImportLayoutMockup.catalog({Key? key}) : this._(true, key: key);

  final bool _catalog;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: CustomPaint(
        painter: _catalog ? _CatalogPainter() : _TablePainter(),
        size: Size.infinite,
      ),
    );
  }
}

class _TablePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final pad = size.width * 0.08;
    final rect = Rect.fromLTRB(pad, pad, size.width - pad, size.height - pad);
    const cols = 4;
    const rows = 6;
    final cw = rect.width / cols;
    final rh = rect.height / rows;

    final header = Paint()..color = AppColors.brown700;
    canvas.drawRect(Rect.fromLTWH(rect.left, rect.top, rect.width, rh), header);

    final cellA = Paint()..color = AppColors.creamCard;
    final cellB = Paint()..color = AppColors.brown100;
    for (var r = 1; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        canvas.drawRect(
          Rect.fromLTWH(rect.left + c * cw, rect.top + r * rh, cw, rh),
          r.isEven ? cellA : cellB,
        );
      }
    }

    final line = Paint()
      ..color = AppColors.brown300
      ..strokeWidth = 1;
    for (var c = 0; c <= cols; c++) {
      canvas.drawLine(Offset(rect.left + c * cw, rect.top), Offset(rect.left + c * cw, rect.bottom), line);
    }
    for (var r = 0; r <= rows; r++) {
      canvas.drawLine(Offset(rect.left, rect.top + r * rh), Offset(rect.right, rect.top + r * rh), line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CatalogPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final pad = size.width * 0.07;
    final rect = Rect.fromLTRB(pad, pad, size.width - pad, size.height - pad);
    const cols = 3;
    const rows = 2;
    final gap = size.width * 0.04;
    final cw = (rect.width - gap * (cols - 1)) / cols;
    final ch = (rect.height - gap * (rows - 1)) / rows;

    final card = Paint()..color = AppColors.creamCard;
    final border = Paint()
      ..color = AppColors.brown300
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final photo = Paint()..color = AppColors.brown200;
    final textLine = Paint()
      ..color = AppColors.brown400
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final left = rect.left + c * (cw + gap);
        final top = rect.top + r * (ch + gap);
        final box = Rect.fromLTWH(left, top, cw, ch);
        final rr = RRect.fromRectAndRadius(box, const Radius.circular(3));
        canvas.drawRRect(rr, card);
        canvas.drawRRect(rr, border);

        final inset = cw * 0.16;
        final photoRect = Rect.fromLTWH(left + inset, top + inset, cw - inset * 2, ch * 0.42);
        canvas.drawRRect(RRect.fromRectAndRadius(photoRect, const Radius.circular(2)), photo);

        for (var i = 0; i < 3; i++) {
          final y = photoRect.bottom + inset * 0.7 + i * (ch * 0.13);
          canvas.drawLine(Offset(left + inset, y), Offset(left + cw - inset * (i == 2 ? 3 : 1), y), textLine);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
