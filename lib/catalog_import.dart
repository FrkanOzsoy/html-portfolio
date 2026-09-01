import 'dart:typed_data';
import 'package:excel/excel.dart' hide Border;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'normalize.dart';

export 'price_list_grid.dart';

/// Catalog ("Katalog -- resimli kutucuklu") price-list import -- the other
/// shape of supplier price list. Instead of one flat table with a header
/// row, every product is a little card: its photo, then a fixed vertical
/// list of labelled fields underneath --
///
/// ```
/// Kategori           Bisküvi
///                    BURÇAK 3LÜ
/// Ürün Adı           393GX14KL
/// Ürün Kodu          3511001
/// Ürün Barkodu       8690526661100
/// Birim Fiyat        57,82
/// Kdv Dahil          58,40
/// Öneri Satış Fiyat  73,00
/// Raf Ömrü           12 Ay
/// Koli Fiyatı Brüt   ₺831,75
/// ```
///
/// -- several cards per row, many rows per page. The normal-table import
/// (excel_import.dart / pdf_import.dart -> price_list_grid.dart) cannot
/// read these: there is no single header row, and no column that a given
/// value lives in.
///
/// This reconstructs one plain `List<List<String>>` grid -- the exact
/// shape price_list_grid.dart and bulk_price_import_screen.dart already
/// consume -- with a synthetic header row prepended, one data row per
/// card. Column meaning is fixed here (we know this layout), so the review
/// screen skips detectColumns for catalog files and starts from
/// [catalogColumnGuess]; its remap dropdowns still let a human repoint a
/// column (e.g. use "Birim Fiyat" instead of "Öneri Satış Fiyat" as the
/// shelf price).
///
/// Both a text-layer PDF catalog and its source Excel are handled -- a
/// supplier who sends the PDF can usually also send the .xlsx it was
/// exported from, and the Excel is the more reliable input (real gridded
/// cells; a wrapped product name stays in one cell instead of shoving
/// every value below it down a row the way it does in the PDF's text
/// layer). A scanned/photographed catalog has no text layer and yields an
/// empty result -- that needs OCR, not attempted here.

/// Header row prepended to every catalog grid. Order matches the row built
/// in [_boxToRow]; the review screen's dropdowns show these verbatim.
const List<String> catalogHeader = [
  'Ürün Barkodu',
  'Ürün Adı',
  'Kategori',
  'Birim Fiyat',
  'KDV Dahil',
  'Öneri Satış Fiyat',
  'Koli Fiyatı',
];

/// Fixed column mapping for a catalog grid (indices into [catalogHeader]).
/// "Öneri Satış Fiyat" is the default price -- it is the recommended shelf
/// price, which is what actually goes on the label; "Birim Fiyat" / "KDV
/// Dahil" are what the store *pays*. dataStartRow 1 skips the header.
class CatalogColumns {
  final int barcodeCol;
  final int nameCol;
  final int priceCol;
  final int? kdvCol;
  final int dataStartRow;

  const CatalogColumns({
    required this.barcodeCol,
    required this.nameCol,
    required this.priceCol,
    required this.kdvCol,
    required this.dataStartRow,
  });
}

const catalogColumnGuess = CatalogColumns(
  barcodeCol: 0,
  nameCol: 1,
  priceCol: 5,
  kdvCol: null,
  dataStartRow: 1,
);

class CatalogResult {
  /// Header row + one row per card that had a usable barcode.
  final List<List<String>> grid;

  /// Cards that looked filled in (had any real field, not just a "₺0,00"
  /// placeholder cell) -- the denominator the review screen reports.
  final int totalBoxes;

  /// Cards actually emitted (barcode present and 8-14 digits).
  final int keptBoxes;

  const CatalogResult({required this.grid, required this.totalBoxes, required this.keptBoxes});
}

// --- field kinds -------------------------------------------------------------

enum _Field { kategori, name, kod, barkod, birim, kdv, oneri, raf, koli }

/// Label text (Turkish-folded) -> which field the value beside it is.
const Map<String, _Field> _labels = {
  'kategori': _Field.kategori,
  'urun adi': _Field.name,
  'urun kodu': _Field.kod,
  'urun barkodu': _Field.barkod,
  'birim fiyat': _Field.birim,
  'kdv dahil': _Field.kdv,
  'oneri satis fiyat': _Field.oneri,
  'raf omru': _Field.raf,
  'koli fiyati brut': _Field.koli,
};

/// Longest label phrase is 3 words ("oneri satis fiyat").
const _maxLabelWords = 3;

/// Pseudo-points per spreadsheet row, so the Excel path can reuse the
/// PDF's point-based vertical tolerances in [_boxToRow].
const _rowUnit = 14.0;

// --- a card's raw collected content, format-agnostic ------------------------

class _Box {
  final List<_Cell> values = [];
  final Map<_Field, double> labelY = {};
}

class _Cell {
  final String text;
  final double y;

  const _Cell(this.text, this.y);

  bool get isBlank {
    final t = text.trim();
    return t.isEmpty || t == '0,00' || t == '₺0,00' || t == '0.00';
  }
}

/// A card slot that carried a real product (a price or a barcode-length
/// code), as opposed to an empty grid cell that only holds a leftover
/// "Bar" category word or a "₺0,00" placeholder. This is the denominator
/// for the "N/M read" note -- counting every empty slot would make a
/// perfectly-parsed page look half-failed.
bool _looksLikeProduct(_Box box) {
  for (final c in box.values) {
    if (c.isBlank) continue;
    final flat = _clean(c.text);
    if (_barcodeRe.hasMatch(flat) || _priceRe.hasMatch(flat)) return true;
  }
  return false;
}

// --- shared classification: a filled _Box -> one grid row ------------------

/// A price always carries a decimal separator in these catalogs ("19,80",
/// "₺1.115,20", or "19.8" once Excel has serialised the cell). Requiring
/// the separator is what keeps a bare "Ürün Kodu" (a 6-7 digit integer)
/// out of the price bucket.
final _priceRe = RegExp(r'^₺?\s*\d{1,3}(?:[.\s]\d{3})*[.,]\d{1,2}$');
final _barcodeRe = RegExp(r'^\d{8,14}$');
final _intCodeRe = RegExp(r'^\d{1,7}$');
final _shelfLifeRe = RegExp(r'^\d+\s*ay$');

bool _isValidEan13(String b) {
  if (b.length != 13) return false;
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    sum += (b.codeUnitAt(i) - 48) * (i.isEven ? 1 : 3);
  }
  return (10 - (sum % 10)) % 10 == (b.codeUnitAt(12) - 48);
}

String _clean(String s) => s.replaceAll('₺', '').replaceAll(RegExp(r'\s'), '').trim();

/// Turns a card's loose value cells into `[barcode, name, category, birim,
/// kdv, oneri, koli]`. Deliberately does NOT trust "label X is on the same
/// line as value Y": in the PDF text layer a two-line product name shoves
/// every value below it down one row, so the value next to the "Ürün
/// Barkodu" label can actually be the stock code, etc. Instead every value
/// is classified by its own shape, and the (up to four) prices are put
/// back in order by their vertical position -- which the row shift
/// preserves. Birim < KDV <= Öneri, and Koli (a case of ~20) is much
/// bigger and the only one printed with a ₺ sign, so the order is safe.
List<String>? _boxToRow(_Box box) {
  final cells = box.values.where((c) => !c.isBlank).toList();
  if (cells.isEmpty) return null;

  String? barcode;
  final numericCodes = <String>[];
  final prices = <({double value, double y, bool lira})>[];
  final nameParts = <_Cell>[];
  final categoryParts = <_Cell>[];

  final yKat = box.labelY[_Field.kategori];
  final yName = box.labelY[_Field.name];
  final yBirim = box.labelY[_Field.birim];
  // Product name sits between the "Kategori" line and the first price line
  // (it spans the blank line above the "Ürün Adı" label, that label's own
  // line, and any wrap line below it). Category sits on the "Kategori"
  // line itself.
  final nameTop = yKat != null ? yKat + 4 : double.negativeInfinity;
  final nameBottom = yBirim ?? (yName != null ? yName + 40 : double.infinity);

  for (final c in cells) {
    final t = c.text.trim();
    final flat = _clean(t);
    if (_barcodeRe.hasMatch(flat)) {
      if (flat.length == 13) {
        // Prefer a checksum-valid EAN-13; fall back to the first 13-digit
        // token if none validates (some private-label codes are off).
        if (barcode == null || (!_isValidEan13(barcode) && _isValidEan13(flat))) barcode = flat;
      } else {
        numericCodes.add(flat);
      }
      continue;
    }
    if (_intCodeRe.hasMatch(flat)) continue; // "Ürün Kodu" (6-7 digits), page nums
    if (_shelfLifeRe.hasMatch(normalizeTurkish(t))) continue; // "12 Ay"
    if (_priceRe.hasMatch(flat)) {
      final n = _parsePrice(flat);
      if (n != null && n > 0) {
        prices.add((value: n, y: c.y, lira: t.contains('₺')));
        continue;
      }
    }
    if (RegExp(r'[A-Za-zÇĞİÖŞÜçğıöşü]').hasMatch(t)) {
      if (c.y <= (yKat ?? double.negativeInfinity) + 4 && yKat != null) {
        categoryParts.add(c);
      } else if (c.y > nameTop && c.y < nameBottom) {
        nameParts.add(c);
      }
    }
  }

  // No real barcode -> nothing we can safely match on. If there is exactly
  // one long numeric code and it is 12/14 digits, take it as the barcode.
  if (barcode == null && numericCodes.length == 1 && {12, 14}.contains(numericCodes.first.length)) {
    barcode = numericCodes.first;
  }
  if (barcode == null) return null;

  ({double value, double y, bool lira})? koli;
  final rest = <({double value, double y, bool lira})>[];
  for (final p in prices) {
    if (p.lira) {
      koli = (koli == null || p.value > koli.value) ? p : koli;
    } else {
      rest.add(p);
    }
  }
  if (koli == null && rest.length > 3) {
    // No ₺ sign anywhere -- the case price is just the biggest number.
    rest.sort((a, b) => b.value.compareTo(a.value));
    koli = rest.removeAt(0);
  }
  rest.sort((a, b) => a.y.compareTo(b.y));
  String p(int i) => i < rest.length ? _fmt(rest[i].value) : '';

  final name = _joinReading(nameParts);
  final category = _joinReading(categoryParts);

  return [
    barcode,
    name,
    category,
    p(0), // Birim Fiyat
    p(1), // KDV Dahil
    p(2), // Öneri Satış Fiyat
    koli != null ? _fmt(koli.value) : '',
  ];
}

double? _parsePrice(String raw) {
  var s = raw.replaceAll('₺', '').replaceAll(' ', '');
  final hasComma = s.contains(','), hasDot = s.contains('.');
  if (hasComma && hasDot) {
    s = s.replaceAll('.', '').replaceAll(',', '.');
  } else if (hasComma) {
    s = s.replaceAll(',', '.');
  }
  return double.tryParse(s);
}

String _fmt(double v) => v.toStringAsFixed(2);

/// Joins name/category fragments and collapses whitespace. Callers append
/// fragments already in reading order (top line first, then left-to-right),
/// so this keeps insertion order rather than sorting -- Dart's sort isn't
/// stable and would scramble two fragments sharing a y.
String _joinReading(List<_Cell> parts) {
  return parts.map((c) => c.text.trim()).join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

// --- PDF path --------------------------------------------------------------

class _Word {
  final String text;
  final double xc;
  final double yc;
  final double left;
  final double right;
  final double height;

  const _Word(this.text, this.xc, this.yc, this.left, this.right, this.height);
}

CatalogResult catalogFromPdfBytes(Uint8List bytes) {
  final document = PdfDocument(inputBytes: bytes);
  try {
    final lines = PdfTextExtractor(document).extractTextLines();
    final byPage = <int, List<_Word>>{};
    for (final line in lines) {
      for (final w in line.wordCollection) {
        if (w.text.trim().isEmpty) continue;
        final b = w.bounds;
        (byPage[line.pageIndex] ??= []).add(_Word(
          w.text,
          b.left + b.width / 2,
          b.top + b.height / 2,
          b.left,
          b.left + b.width,
          b.height <= 0 ? 10 : b.height,
        ));
      }
    }

    final out = <List<String>>[catalogHeader];
    var total = 0;
    for (final entry in byPage.entries) {
      total += _parsePdfPage(entry.value, out);
    }
    return _finalize(out, total);
  } finally {
    document.dispose();
  }
}

/// De-dupes by barcode (a product listed on two pages) keeping the first
/// row, and collapses the grid to just the header when nothing was read.
CatalogResult _finalize(List<List<String>> gridWithHeader, int total) {
  final seen = <String>{};
  final rows = <List<String>>[gridWithHeader.first];
  for (final r in gridWithHeader.skip(1)) {
    if (seen.add(r[0])) rows.add(r);
  }
  // A product printed on two pages isn't a "lost" row -- drop it from the
  // denominator too, so the note only counts cards we genuinely couldn't read.
  final dupes = (gridWithHeader.length - 1) - (rows.length - 1);
  return CatalogResult(
    grid: rows.length > 1 ? rows : [],
    totalBoxes: (total - dupes).clamp(rows.length - 1, total),
    keptBoxes: rows.length - 1,
  );
}

/// Parses one page's words, appending product rows to [out]. Returns the
/// number of card slots on the page that looked like real products (the
/// note denominator).
int _parsePdfPage(List<_Word> words, List<List<String>> out) {
  if (words.isEmpty) return 0;

  // Cluster words into visual rows by y-center.
  final sorted = [...words]..sort((a, b) => a.yc.compareTo(b.yc));
  final rows = <List<_Word>>[];
  for (final w in sorted) {
    if (rows.isEmpty) {
      rows.add([w]);
      continue;
    }
    final cur = rows.last;
    final refY = cur.map((e) => e.yc).reduce((a, b) => a + b) / cur.length;
    final tol = cur.map((e) => e.height).reduce((a, b) => a < b ? a : b) * 0.6;
    if ((w.yc - refY).abs() <= tol) {
      cur.add(w);
    } else {
      rows.add([w]);
    }
  }

  // Per row: pull out label phrases, leave the rest as value cells.
  final labels = <({_Field kind, double x, double y})>[];
  final cellsXY = <({String text, double x, double y})>[];
  for (final row in rows) {
    final ws = [...row]..sort((a, b) => a.left.compareTo(b.left));
    final consumed = List<bool>.filled(ws.length, false);
    for (var i = 0; i < ws.length; i++) {
      if (consumed[i]) continue;
      for (var n = _maxLabelWords; n >= 1; n--) {
        if (i + n > ws.length) continue;
        final phrase = normalizeTurkish(ws.sublist(i, i + n).map((w) => w.text).join(' '));
        final kind = _labels[phrase];
        if (kind != null) {
          labels.add((kind: kind, x: ws[i].left, y: ws[i].yc));
          for (var j = i; j < i + n; j++) {
            consumed[j] = true;
          }
          break;
        }
      }
    }
    // Remaining words -> cells, split on a wide x-gap.
    String? curText;
    double? curLeft, curRight, curY;
    void flush() {
      if (curText != null) cellsXY.add((text: curText!, x: (curLeft! + curRight!) / 2, y: curY!));
      curText = null;
    }

    for (var i = 0; i < ws.length; i++) {
      if (consumed[i]) {
        flush();
        continue;
      }
      final w = ws[i];
      if (curText == null) {
        curText = w.text.trim();
        curLeft = w.left;
        curRight = w.right;
        curY = w.yc;
      } else if (w.left - curRight! > 10) {
        flush();
        curText = w.text.trim();
        curLeft = w.left;
        curRight = w.right;
        curY = w.yc;
      } else {
        curText = '$curText ${w.text.trim()}';
        curRight = w.right;
      }
    }
    flush();
  }

  // "Kategori" labels lay out the card grid: their y-values are the row
  // tops, their x-values the column lefts.
  final katYs = _cluster(labels.where((l) => l.kind == _Field.kategori).map((l) => l.y).toList(), 6);
  final katXs = _cluster(labels.where((l) => l.kind == _Field.kategori).map((l) => l.x).toList(), 25);
  if (katYs.isEmpty || katXs.isEmpty) return 0;
  katYs.sort();
  katXs.sort();

  final maxX = words.map((w) => w.right).reduce((a, b) => a > b ? a : b) + 10;
  final maxY = words.map((w) => w.yc).reduce((a, b) => a > b ? a : b) + 200;

  double rightBound(List<double> edges, int i, double last) => i + 1 < edges.length ? edges[i + 1] - 12 : last;

  var total = 0;
  for (var ri = 0; ri < katYs.length; ri++) {
    final yTop = katYs[ri] - 8;
    final yBot = rightBound(katYs, ri, maxY);
    for (var ci = 0; ci < katXs.length; ci++) {
      final xLeft = katXs[ci] - 12;
      final xRight = rightBound(katXs, ci, maxX);
      final box = _Box();
      for (final l in labels) {
        if (l.y >= yTop && l.y < yBot && l.x >= xLeft && l.x < xRight) {
          box.labelY.putIfAbsent(l.kind, () => l.y);
        }
      }
      for (final c in cellsXY) {
        if (c.y >= yTop && c.y < yBot && c.x >= xLeft && c.x < xRight) {
          box.values.add(_Cell(c.text, c.y));
        }
      }
      if (box.values.isEmpty) continue;
      final row = _boxToRow(box);
      if (row != null) {
        out.add(row);
        total++;
      } else if (_looksLikeProduct(box)) {
        total++;
      }
    }
  }
  return total;
}

/// 1-D agglomerative clustering: sorts values, starts a new cluster when
/// the gap to the running cluster mean exceeds [gap], returns cluster
/// means. Used to fold the ~5 slightly-jittery "Kategori" x-positions (and
/// ~7 row y-positions) into clean column/row edges.
List<double> _cluster(List<double> values, double gap) {
  if (values.isEmpty) return [];
  final s = [...values]..sort();
  final clusters = <List<double>>[
    [s.first],
  ];
  for (final v in s.skip(1)) {
    final cur = clusters.last;
    final mean = cur.reduce((a, b) => a + b) / cur.length;
    if (v - mean <= gap) {
      cur.add(v);
    } else {
      clusters.add([v]);
    }
  }
  return [for (final c in clusters) c.reduce((a, b) => a + b) / c.length];
}

// --- Excel path -----------------------------------------------------------

CatalogResult catalogFromExcelBytes(Uint8List bytes) {
  final excel = Excel.decodeBytes(bytes);
  if (excel.tables.isEmpty) return const CatalogResult(grid: [], totalBoxes: 0, keptBoxes: 0);
  final sheet = excel.tables[excel.tables.keys.first]!;
  final cells = [
    for (final row in sheet.rows)
      [
        for (final cell in row)
          switch (cell?.value) {
            null => '',
            TextCellValue v => v.value.toString().trim(),
            IntCellValue v => v.value.toString(),
            DoubleCellValue v => v.value.toString(),
            final v => v.toString().trim(),
          },
      ],
  ];
  return catalogFromCellGrid(cells);
}

/// Excel catalog: cells are already a real grid and a wrapped name stays
/// inside one cell, so -- unlike the PDF -- a label's value really is the
/// next non-empty cell to its right. Each "Ürün Barkodu" label cell marks
/// one card; the other fields are found by their own labels in the same
/// label column, within a few rows.
CatalogResult catalogFromCellGrid(List<List<String>> cells) {
  final labelAt = <({int r, int c, _Field kind})>[];
  for (var r = 0; r < cells.length; r++) {
    final row = cells[r];
    for (var c = 0; c < row.length; c++) {
      for (var n = _maxLabelWords; n >= 1; n--) {
        if (c + n > row.length) continue;
        final phrase = normalizeTurkish(row.sublist(c, c + n).join(' '));
        final kind = _labels[phrase];
        if (kind != null) {
          labelAt.add((r: r, c: c, kind: kind));
          break;
        }
      }
    }
  }

  String valueRightOf(int r, int c) {
    final row = r < cells.length ? cells[r] : const <String>[];
    for (var k = c + 1; k < row.length && k <= c + 4; k++) {
      if (row[k].trim().isNotEmpty) return row[k].trim();
    }
    return '';
  }

  // Barcode label rows per column -- one per card. A card's other fields
  // are whatever labels sit between the previous and next barcode in the
  // same column (Kategori/Ürün Adı above, the prices below), so two
  // adjacent cards never borrow each other's rows regardless of how tall
  // a wrapped name made one of them.
  final barkodRowsByCol = <int, List<int>>{};
  for (final l in labelAt.where((l) => l.kind == _Field.barkod)) {
    (barkodRowsByCol[l.c] ??= []).add(l.r);
  }
  for (final v in barkodRowsByCol.values) {
    v.sort();
  }

  final out = <List<String>>[catalogHeader];
  var total = 0;
  for (final anchor in labelAt.where((l) => l.kind == _Field.barkod)) {
    final box = _Box();
    final siblings = barkodRowsByCol[anchor.c]!;
    final idx = siblings.indexOf(anchor.r);
    final loBound = idx > 0 ? (anchor.r + siblings[idx - 1]) ~/ 2 : anchor.r - 9;
    final hiBound = idx + 1 < siblings.length ? (anchor.r + siblings[idx + 1]) ~/ 2 : anchor.r + 8;
    // Row indices are scaled by _rowUnit so _boxToRow's point-based y
    // tolerances (tuned for the PDF) behave the same here.
    final near = labelAt.where((l) => l.c == anchor.c && l.r > loBound && l.r <= hiBound).toList()
      ..sort((a, b) => a.r.compareTo(b.r));
    for (final l in near) {
      box.labelY.putIfAbsent(l.kind, () => l.r * _rowUnit);
      // The line just above "Ürün Adı" often carries the first half of the
      // product name -- add it before the label's own value so the two
      // read in order.
      if (l.kind == _Field.name && l.r - 1 >= 0) {
        final above = valueRightOf(l.r - 1, l.c);
        if (above.isNotEmpty && RegExp(r'[A-Za-zÇĞİÖŞÜçğıöşü]').hasMatch(above)) {
          box.values.add(_Cell(above, (l.r - 1) * _rowUnit));
        }
      }
      final v = valueRightOf(l.r, l.c);
      if (v.isNotEmpty) box.values.add(_Cell(v, l.r * _rowUnit));
    }
    if (box.values.isEmpty) continue;
    final row = _boxToRow(box);
    if (row != null) {
      out.add(row);
      total++;
    } else if (_looksLikeProduct(box)) {
      total++;
    }
  }
  return _finalize(out, total);
}

// --- layout auto-detect --------------------------------------------------

/// True when [text] (raw extracted PDF text, or all Excel cells joined)
/// carries the repeated field labels of a catalog rather than a flat
/// table. Used only to pre-select the right choice in the layout picker --
/// the user can always override it.
bool looksLikeCatalog(String text) {
  final n = normalizeTurkish(text);
  final barkod = RegExp(r'urun barkodu').allMatches(n).length;
  final oneri = RegExp(r'oneri satis fiyat').allMatches(n).length;
  return barkod >= 3 || oneri >= 3;
}
