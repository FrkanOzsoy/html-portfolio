import 'package:flutter_test/flutter_test.dart';
import 'package:barkod_tarayici/catalog_import.dart';

/// One catalog card as label/value cell pairs, in the fixed field order.
/// `name` may contain a `\n` to force a wrapped (two-line) product name,
/// which in the source sheet lands on the row above the "Ürün Adı" label.
List<List<String>> _card({
  required String category,
  required String name,
  String kod = '1234567',
  required String barcode,
  String birim = '',
  String kdv = '',
  String oneri = '',
  String rafOmru = '12 Ay',
  String koli = '',
}) {
  final parts = name.split('\n');
  final nameTop = parts.length > 1 ? parts.first : '';
  final nameLabelValue = parts.length > 1 ? parts[1] : parts.first;
  return [
    ['Kategori', category],
    ['', nameTop],
    ['Ürün Adı', nameLabelValue],
    ['Ürün Kodu', kod],
    ['Ürün Barkodu', barcode],
    ['Birim Fiyat', birim],
    ['Kdv Dahil', kdv],
    ['Öneri Satış Fiyat', oneri],
    ['Raf Ömrü', rafOmru],
    ['Koli Fiyatı Brüt', koli],
    ['', ''],
  ];
}

List<List<String>> _sheet(List<List<List<String>>> cards) => [for (final c in cards) ...c];

void main() {
  test('plain card -> row with prices in label order', () {
    final res = catalogFromCellGrid(_sheet([
      _card(
        category: 'Bisküvi',
        name: 'BURÇAK 3LÜ 393GX14KL',
        barcode: '8690526661100',
        birim: '57,82',
        kdv: '58,40',
        oneri: '73,00',
        koli: '₺831,75',
      ),
    ]));
    expect(res.grid.first, catalogHeader);
    expect(res.grid[1], ['8690526661100', 'BURÇAK 3LÜ 393GX14KL', 'Bisküvi', '57.82', '58.40', '73.00', '831.75']);
    expect(res.keptBoxes, 1);
  });

  test('wrapped product name is stitched back together', () {
    final res = catalogFromCellGrid(_sheet([
      _card(
        category: 'Bisküvi',
        name: 'BURCAK KAK.KR.YUL.3LÜ\n246GX9',
        barcode: '8690526653945',
        birim: '59,01',
        kdv: '59,60',
        oneri: '74,50',
        koli: '₺531,09',
      ),
    ]));
    expect(res.grid[1][1], 'BURCAK KAK.KR.YUL.3LÜ 246GX9');
    expect(res.grid[1].sublist(3), ['59.01', '59.60', '74.50', '531.09']);
  });

  test('case price with no ₺ sign is still separated from unit prices', () {
    final res = catalogFromCellGrid(_sheet([
      _card(
        category: 'Bar',
        name: 'CANGA ANTEP 40GX16KL',
        barcode: '8690526420905',
        birim: '47,52',
        kdv: '48,00',
        oneri: '60,00',
        koli: '760,32',
      ),
    ]));
    expect(res.grid[1].sublist(3), ['47.52', '48.00', '60.00', '760.32']);
  });

  test('the stock code is never mistaken for a price', () {
    final res = catalogFromCellGrid(_sheet([
      _card(category: 'Bar', name: 'X 10GX1', kod: '1672500', barcode: '8690526047256', birim: '19,80', kdv: '20,00', oneri: '25,00', koli: '₺316,80'),
    ]));
    expect(res.grid[1].sublist(3), ['19.80', '20.00', '25.00', '316.80']);
  });

  test('empty placeholder card is dropped', () {
    final res = catalogFromCellGrid(_sheet([
      _card(category: 'Bar', name: '', kod: '', barcode: '', koli: '₺0,00'),
      _card(category: 'Bar', name: 'REAL 1GX1', barcode: '8690526940649', oneri: '25,00'),
    ]));
    expect(res.keptBoxes, 1);
    expect(res.grid[1][0], '8690526940649');
  });

  test('a product listed twice yields one row', () {
    final card = _card(category: 'Bar', name: 'DUP 1GX1', barcode: '8690526837437', oneri: '25,00');
    final res = catalogFromCellGrid(_sheet([card, card]));
    expect(res.keptBoxes, 1);
  });

  test('non-catalog grid yields nothing', () {
    final res = catalogFromCellGrid([
      ['Barkod', 'Ad', 'Fiyat'],
      ['8690526837437', 'Bir Şey', '25,00'],
    ]);
    expect(res.grid, isEmpty);
  });

  test('looksLikeCatalog keys off the repeated field labels', () {
    expect(looksLikeCatalog('Ürün Barkodu 1  Ürün Barkodu 2  Ürün Barkodu 3'), isTrue);
    expect(looksLikeCatalog('Barkod\tAd\tFiyat\n869...\tX\t25'), isFalse);
  });
}
