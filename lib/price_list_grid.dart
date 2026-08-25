import 'normalize.dart';

/// Bulk price-list import (supplier Excel/PDF files) -- no LLM involved.
/// Format-agnostic: everything here works on a plain `List<List<String>>`
/// grid, so the same heuristic serves both excel_import.dart (an Excel
/// sheet's cells, already gridded) and pdf_import.dart (a PDF's text
/// reconstructed into a grid by whitespace-gap clustering, much less
/// reliably gridded to begin with).
///
/// Column meaning is guessed from two signals only: header text keywords
/// (Turkish, e.g. "Barkod"/"Fiyat"/"KDV") when a header row exists, and the
/// *shape* of the data itself (a barcode is an all-digit string of a
/// standard length, a price parses as a plausible number, a name is mostly
/// letters) when it doesn't. Neither signal is trusted blindly --
/// [detectColumns] only ever produces a *starting guess*; the review screen
/// (bulk_price_import_screen.dart) always shows it to a human before
/// anything is staged, with dropdowns to fix a wrong guess. Suppliers vary
/// too much in layout for a fully automatic mapping to be safe for
/// something that ends up as real prices.

/// Turkish price-list numbers show up as "325", "325.50", "325,50", or
/// "1.234,56" (dot thousands + comma decimal) depending on the supplier's
/// own locale settings when they exported the sheet/PDF.
num? parseFlexibleNumber(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'[₺$€%\s]'), '').replaceAll(RegExp(r'[tT][lL]$'), '');
  if (s.isEmpty) return null;
  final hasComma = s.contains(',');
  final hasDot = s.contains('.');
  if (hasComma && hasDot) {
    s = s.replaceAll('.', '').replaceAll(',', '.');
  } else if (hasComma) {
    s = s.replaceAll(',', '.');
  }
  return num.tryParse(s);
}

bool looksLikeBarcode(String s) {
  return RegExp(r'^\d+$').hasMatch(s) && {8, 12, 13, 14}.contains(s.length);
}

/// Looser than [looksLikeBarcode] -- deliberately *not* used for column
/// detection (a short numeric column is too easily some other internal
/// code, e.g. a 6-digit stok kodu), but used to validate an individual row
/// once the barcode column is already known (by heuristic or a human's
/// remap). This store's own produce items use short internal codes (e.g.
/// "2701034" for a specific vegetable) instead of real EAN barcodes --
/// requiring standard EAN/UPC lengths here would wrongly reject those as
/// "invalid" even though they're genuinely how this store's data works.
bool isPlausibleBarcode(String s) => RegExp(r'^\d{1,14}$').hasMatch(s);

/// Same mod-10 EAN-13 check the till-PC bridge itself validates against
/// (see productCreateSync.ts's isValidEan13) -- flagging a bad check digit
/// here, before anything reaches Kasaya Gönder, is much cheaper than
/// finding out from a rejected request later. Anything not exactly 13
/// digits is left unvalidated (no standard mod-10 check applies uniformly
/// to EAN-8/UPC-A/ITF-14).
bool isValidEan13(String barcode) {
  if (!RegExp(r'^\d{13}$').hasMatch(barcode)) return true;
  final digits = barcode.split('').map(int.parse).toList();
  final checkDigit = digits[12];
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    sum += digits[i] * (i % 2 == 0 ? 1 : 3);
  }
  final expected = (10 - (sum % 10)) % 10;
  return expected == checkDigit;
}

String excelColumnLetter(int index) {
  var n = index;
  var s = '';
  do {
    s = String.fromCharCode(65 + (n % 26)) + s;
    n = (n ~/ 26) - 1;
  } while (n >= 0);
  return s;
}

class ColumnGuess {
  final int? barcodeCol;
  final int? nameCol;
  final int? priceCol;
  final int? kdvCol;
  final int headerRowIndex; // -1 when no header row was detected
  final int dataStartRow;

  const ColumnGuess({
    this.barcodeCol,
    this.nameCol,
    this.priceCol,
    this.kdvCol,
    required this.headerRowIndex,
    required this.dataStartRow,
  });
}

/// A short, human-readable label for a column in the remap dropdowns --
/// its header text if there was a usable header row, otherwise the plain
/// spreadsheet-style letter (A, B, C, ...), since for a PDF there's no
/// underlying "real" column letter to refer back to anyway.
String columnLabel(List<List<String>> grid, int headerRowIndex, int col) {
  if (headerRowIndex >= 0 && headerRowIndex < grid.length) {
    final row = grid[headerRowIndex];
    final text = col < row.length ? row[col] : '';
    if (text.isNotEmpty) return '${excelColumnLetter(col)}: $text';
  }
  return excelColumnLetter(col);
}

ColumnGuess detectColumns(List<List<String>> grid) {
  if (grid.isEmpty) return const ColumnGuess(headerRowIndex: -1, dataStartRow: 0);
  var colCount = 0;
  for (final r in grid) {
    if (r.length > colCount) colCount = r.length;
  }
  if (colCount == 0) return const ColumnGuess(headerRowIndex: -1, dataStartRow: 0);

  // A header row's cells mostly won't look like barcode/price data -- the
  // first row where that's true is a *candidate*, but a lone title/banner
  // row above the real header (e.g. "ABC GIDA - Ağustos 2026 Fiyat
  // Listesi" sitting alone in the first cell) also fails the data-shape
  // test without being a real header -- it only ever populates one or two
  // cells, where a genuine header labels most/all columns. Skip sparse
  // candidates and keep looking (checked only in the first several rows,
  // real files don't bury the header under more than a title or two). If
  // the very first non-empty row already looks like data, there's no
  // header at all.
  var headerRowIndex = -1;
  for (var r = 0; r < grid.length && r < 8; r++) {
    final texts = [for (var c = 0; c < colCount; c++) (c < grid[r].length ? grid[r][c] : '')];
    final nonEmpty = texts.where((t) => t.isNotEmpty).toList();
    if (nonEmpty.isEmpty) continue;
    final dataShaped = nonEmpty.where((t) => looksLikeBarcode(t) || parseFlexibleNumber(t) != null).length;
    if (dataShaped / nonEmpty.length >= 0.3) break; // hit real data, no header found above it
    if (nonEmpty.length < 2 || nonEmpty.length < colCount * 0.4) continue; // too sparse to be a real header
    headerRowIndex = r;
    break;
  }

  final dataStart = headerRowIndex + 1;
  final sampleEnd = (dataStart + 60).clamp(0, grid.length);

  final headerTexts = List.generate(
    colCount,
    (c) => headerRowIndex >= 0
        ? normalizeTurkish(c < grid[headerRowIndex].length ? grid[headerRowIndex][c] : '')
        : '',
  );

  final barcodeScore = List.filled(colCount, 0.0);
  final priceScore = List.filled(colCount, 0.0);
  final nameScore = List.filled(colCount, 0.0);
  final kdvScore = List.filled(colCount, 0.0);

  for (var c = 0; c < colCount; c++) {
    var nonEmpty = 0, barcodeHits = 0, priceHits = 0, nameHits = 0, kdvHits = 0;
    for (var r = dataStart; r < sampleEnd; r++) {
      final row = r < grid.length ? grid[r] : const <String>[];
      final text = c < row.length ? row[c] : '';
      if (text.isEmpty) continue;
      nonEmpty++;
      if (looksLikeBarcode(text)) {
        barcodeHits++;
        continue; // a barcode-shaped value is never also a price/KDV/name
      }
      final n = parseFlexibleNumber(text);
      if (n != null) {
        if (n > 0 && n < 100000) priceHits++;
        if (n == 0 || n == 1 || n == 8 || n == 10 || n == 18 || n == 20) kdvHits++;
      } else if (RegExp(r'[a-zA-ZçğıöşüÇĞİÖŞÜ]').hasMatch(text) && text.length > 2) {
        nameHits++;
      }
    }
    if (nonEmpty == 0) continue;
    barcodeScore[c] = barcodeHits / nonEmpty;
    priceScore[c] = priceHits / nonEmpty;
    nameScore[c] = nameHits / nonEmpty;
    kdvScore[c] = kdvHits / nonEmpty;

    // A supplier's own column header is a far stronger signal than the
    // data shape when it's there -- boost decisively rather than nudging.
    final h = headerTexts[c];
    if (h.isNotEmpty) {
      if (RegExp(r'barkod|ean|gtin').hasMatch(h)) barcodeScore[c] += 1.0;
      if (RegExp(r'fiyat|tutar|ucret').hasMatch(h)) {
        priceScore[c] += 1.0;
        // A price-raise list commonly carries both a purchase and a sale
        // price column (see Digisoft's own "ALIŞ FİYATI 1"/"SATIŞ FİYAT1")
        // -- both match the generic "fiyat" keyword equally, so without a
        // tie-break the earlier (leftmost) column would win regardless of
        // which one it actually is. We want the sale/list price, not what
        // the store paid for it.
        if (RegExp(r'alis').hasMatch(h)) priceScore[c] -= 0.5;
        if (RegExp(r'satis|liste|perakende').hasMatch(h)) priceScore[c] += 0.5;
      }
      if (RegExp(r'(^| )ad($| )|isim|urun|tanim|aciklama').hasMatch(h)) nameScore[c] += 1.0;
      if (RegExp(r'kdv|vat').hasMatch(h)) kdvScore[c] += 1.0;
    }
  }

  int? pick(List<double> scores, double minScore, Set<int> taken) {
    int? best;
    var bestScore = minScore;
    for (var c = 0; c < scores.length; c++) {
      if (taken.contains(c)) continue;
      if (scores[c] > bestScore) {
        bestScore = scores[c];
        best = c;
      }
    }
    return best;
  }

  final taken = <int>{};
  final barcodeCol = pick(barcodeScore, 0.5, taken);
  if (barcodeCol != null) taken.add(barcodeCol);
  final priceCol = pick(priceScore, 0.5, taken);
  if (priceCol != null) taken.add(priceCol);
  // KDV needs a higher bar -- it's optional and a handful of small prices
  // (e.g. "8", "10", "18") can otherwise look just as KDV-shaped.
  final kdvCol = pick(kdvScore, 0.7, taken);
  if (kdvCol != null) taken.add(kdvCol);
  final nameCol = pick(nameScore, 0.3, taken);

  return ColumnGuess(
    barcodeCol: barcodeCol,
    nameCol: nameCol,
    priceCol: priceCol,
    kdvCol: kdvCol,
    headerRowIndex: headerRowIndex,
    dataStartRow: dataStart,
  );
}

class ImportRow {
  final int sourceRowIndex;
  final String barcode;
  final String? name;
  final num? price;
  final num? kdvRate;

  const ImportRow({required this.sourceRowIndex, required this.barcode, this.name, this.price, this.kdvRate});
}

/// Applies a (possibly staff-corrected) column mapping and produces the
/// actual rows -- called fresh every time the mapping changes in the
/// review screen, so a fix to one dropdown re-parses everything.
List<ImportRow> parseRows(
  List<List<String>> grid, {
  required int dataStartRow,
  int? barcodeCol,
  int? nameCol,
  int? priceCol,
  int? kdvCol,
}) {
  if (barcodeCol == null) return const [];
  final out = <ImportRow>[];
  for (var r = dataStartRow; r < grid.length; r++) {
    final row = grid[r];
    String? text(int? c) {
      if (c == null) return null;
      final t = c < row.length ? row[c] : '';
      return t.isEmpty ? null : t;
    }

    final barcodeRaw = text(barcodeCol);
    if (barcodeRaw == null) continue;
    final barcode = barcodeRaw.replaceAll(RegExp(r'\s'), '');
    if (barcode.isEmpty) continue;

    final priceText = text(priceCol);
    final kdvText = text(kdvCol);
    out.add(ImportRow(
      sourceRowIndex: r,
      barcode: barcode,
      name: text(nameCol),
      price: priceText != null ? parseFlexibleNumber(priceText) : null,
      kdvRate: kdvText != null ? parseFlexibleNumber(kdvText) : null,
    ));
  }
  return out;
}
