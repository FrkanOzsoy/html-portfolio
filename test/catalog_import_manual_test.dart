@Tags(['manual'])
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:barkod_tarayici/catalog_import.dart';

/// Runs the catalog PDF parser against a real supplier file kept only on
/// disk (test/fixtures/ is gitignored). Not part of CI -- run explicitly:
///
///   flutter test test/catalog_import_manual_test.dart --tags manual
void main() {
  final fixture = File('test/fixtures/eti_katalog.pdf');

  test('ETİ katalog PDF -> grid', () {
    if (!fixture.existsSync()) {
      markTestSkipped('no fixture at ${fixture.path}');
      return;
    }
    final res = catalogFromPdfBytes(fixture.readAsBytesSync());
    stdout.writeln('boxes: kept ${res.keptBoxes} / filled ${res.totalBoxes}');
    stdout.writeln('grid rows (incl header): ${res.grid.length}');
    stdout.writeln('header: ${res.grid.first}');
    for (final r in res.grid.skip(1).take(25)) {
      stdout.writeln(r.map((c) => c.padRight(14)).join(' | '));
    }

    // Spot-checks pulled straight from the PDF text layer.
    final rows = res.grid.skip(1).toList();
    final byBarcode = {for (final r in rows) r[0]: r};

    // CANGA 45GX16 TV -- clean single-line name, page 1.
    expect(byBarcode.containsKey('8690526047256'), isTrue);
    final canga = byBarcode['8690526047256']!;
    expect(canga[1].toUpperCase(), contains('CANGA'));
    expect(canga[3], '19.80'); // Birim Fiyat
    expect(canga[4], '20.00'); // KDV Dahil
    expect(canga[5], '25.00'); // Öneri Satış Fiyat
    expect(canga[6], '316.80'); // Koli

    // BURCAK KAK.KR.YUL.3LÜ 246GX9 -- the wrapped-name / shifted-value box.
    expect(byBarcode.containsKey('8690526653945'), isTrue);
    final burcak = byBarcode['8690526653945']!;
    expect(burcak[3], '59.01');
    expect(burcak[4], '59.60');
    expect(burcak[5], '74.50');
    expect(burcak[6], '531.09');

    // Every kept row: valid-ish barcode + a positive default price.
    for (final r in rows) {
      expect(isPlausibleBarcode(r[0]), isTrue, reason: 'bad barcode ${r[0]}');
      expect(parseFlexibleNumber(r[catalogColumnGuess.priceCol]), isNotNull, reason: 'no price for ${r[0]}');
    }
    expect(rows.length, greaterThan(200));
  });
}
