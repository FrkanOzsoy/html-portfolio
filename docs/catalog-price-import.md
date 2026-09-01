# Katalog (resimli kutucuklu) fiyat listesi içe aktarma

Fiyat Listesi İçe Aktar artık iki farklı dosya düzenini okuyor. Dosya
seçildikten sonra **"Dosya tipi"** penceresi çıkıyor (iki wordless örnek
çizim, birinin kenarlığı otomatik tahminle işaretli):

| Seçenek | Ne | Parser |
| --- | --- | --- |
| **Normal tablo** | Tek başlıklı düz tablo | `excel_import.dart` / `pdf_import.dart` → `price_list_grid.dart` (değişmedi) |
| **Katalog (resimli)** | Her ürün bir kutucuk: fotoğraf + altında `Kategori / Ürün Adı / Ürün Barkodu / Birim Fiyat / Kdv Dahil / Öneri Satış Fiyat / …` | `catalog_import.dart` (yeni) |

Otomatik tahmin: metinde "Ürün Barkodu" / "Öneri Satış Fiyat" etiketleri
≥3 kez tekrar ediyorsa katalog seçili gelir (`looksLikeCatalog`).

## `catalog_import.dart`

Her iki yol da aynı `List<List<String>>` grid'i üretir — sentetik başlık
satırı + kutucuk başına bir satır. Sütun eşleşmesi sabit
(`catalogColumnGuess`): `barkod=0, ad=1, kategori=2, birim=3, kdv=4,
öneri satış=5, koli=6`; varsayılan fiyat sütunu **Öneri Satış Fiyat** (raf
etiketine giden fiyat). İnceleme ekranı katalog dosyaları için
`detectColumns`'u atlar ama remap dropdown'ları yine çalışır.

### PDF yolu — `catalogFromPdfBytes`

Syncfusion'ın kelime koordinatlarından çalışır, OCR yok:

1. Kelimeler y'ye göre satırlara kümelenir; her satırda soldan sağa
   etiket ifadeleri (`Ürün Barkodu`, `Öneri Satış Fiyat` …) ayıklanır,
   kalanı değer hücreleri olur.
2. "Kategori" etiketleri kart ızgarasını verir — y'leri satır üstleri,
   x'leri sütun solları (`_cluster` ile jitter temizlenir).
3. Her kart bölgesi için değer hücreleri **şekle göre** sınıflanır —
   etiketle aynı satırda olmasına güvenilmez, çünkü **2 satıra taşan ürün
   adı, altındaki bütün değerleri bir kutu aşağı kaydırıyor**:
   - `^\d{13}$` + EAN-13 checksum → barkod
   - `\d{1,7}` düz tamsayı → Ürün Kodu (atılır)
   - `\d+ Ay` → raf ömrü (atılır)
   - ondalık ayraçlı sayılar → fiyatlar; y sırasına dizilir →
     `[Birim, Kdv Dahil, Öneri Satış]`; `₺` işaretli (yoksa en büyük) →
     Koli. Kayma dikey sırayı bozmadığı için bu güvenli.
   - harf içeren, barkodun üstündeki token'lar → ürün adı (taşma satırı
     dahil); "Kategori" satırındakiler → kategori.
4. Sayfalar arası aynı barkod tekrarı tek satıra indirilir.

ETİ Katalog 14.09.2026 (16 sayfa) ile doğrulandı: PDF'teki **332 farklı
barkodun tamamı** okundu. Fikstür `test/fixtures/eti_katalog.pdf`
(gitignore'lu); `flutter test test/catalog_import_manual_test.dart --tags manual`.

### Excel yolu — `catalogFromExcelBytes` / `catalogFromCellGrid`

Excel hücreleri zaten gerçek ızgara ve taşan ad tek hücrede kaldığı için
etiketin değeri gerçekten sağındaki ilk dolu hücre. Her "Ürün Barkodu"
etiket hücresi bir kart; diğer alanlar aynı sütunda, komşu iki barkod
arasında kalan etiketlerden okunur. **Gerçek bir katalog .xlsx ile henüz
test edilmedi** — yapı PDF'ten çıkarıldı, sentetik testler var
(`test/catalog_import_test.dart`).

## DeepSeek gerekmedi

Deterministik parser tüm barkodları yakaladığı için LLM'e ihtiyaç yok.
Tahmini maliyet (referans): metin katmanı gönderilerek katalog başına
~$0.02–0.04 (≈1–1.5 ₺). Zor bir katalog çıkarsa "AI ile çöz" yedeği ayrı
eklenebilir.

## Değişen / yeni dosyalar

- `lib/catalog_import.dart` (yeni)
- `lib/widgets/import_layout_mockup.dart` (yeni — iki örnek çizim)
- `lib/screens/bulk_price_import_screen.dart` — `_askLayout` penceresi,
  katalog dallanması, sabit sütun tahmini
- `test/catalog_import_test.dart` (yeni), `test/catalog_import_manual_test.dart` (yeni)
- `.gitignore` — `/test/fixtures/`
