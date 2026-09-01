class Product {
  final String barcode;
  final String? pluno;
  final String stockname;
  final num? price;
  final String? depno;
  final String? stockunit;
  final String? searchKey;
  // Real per-product VAT rate, synced from Digisoft's own TBLSTOKLAR.SATISKDV
  // by the till-PC bridge (added 2026-08-23) -- replaces the earlier
  // depno-text-matching guess (matchKdvDepartment) entirely. Null just means
  // this row hasn't been touched by the bridge's forward sync since the
  // column was added yet, not "no VAT".
  final num? kdvRate;

  Product({
    required this.barcode,
    this.pluno,
    required this.stockname,
    this.price,
    this.depno,
    this.stockunit,
    this.searchKey,
    this.kdvRate,
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
        barcode: json['barcode'] as String,
        pluno: json['pluno'] as String?,
        stockname: json['stockname'] as String,
        price: json['price'] as num?,
        depno: json['depno'] as String?,
        stockunit: json['stockunit'] as String?,
        searchKey: json['search_key'] as String?,
        kdvRate: json['kdv_rate'] as num?,
      );
}

/// The two fixed lists Teraziye Gönder works with (real rows in `lists`,
/// created for that feature specifically) -- hidden from Listelerim's
/// general browsing since they're not a staff-created shopping list, and
/// referenced here so the Listelerim filter and the Teraziye picker can't
/// drift apart into two different name sets.
const reservedTeraziyeListNames = {'MANAV', 'SARKUTERI'};

/// PLU range on the SARKUTERI list that the "Kasap" İstatistik subsection
/// tracks (real butcher/meat items -- KIYMA, TRANÇ, ANTRIKOT, etc; the
/// SARKUTERI list also carries cheese/deli items at lower PLUs, out of
/// scope here).
const kasapPluMin = 50;
const kasapPluMax = 100;

/// PLU range on the MANAV list the "Manav" İstatistik subsection tracks --
/// the real by-weight produce items; Teraziye stops assigning past PLU44.
const manavPluMin = 1;
const manavPluMax = 44;

/// A KDV (VAT) department -- the till-PC's fixed, pre-set list (e.g.
/// "MANAV" 1%, "MUHTELIF GIDA % 20" 20%). A product's effective KDV rate is
/// set indirectly by assigning it to one of these, not by entering a raw
/// percentage.
class KdvDepartment {
  final int kasadepid;
  final String name;
  final num kdvRate;

  KdvDepartment({required this.kasadepid, required this.name, required this.kdvRate});

  factory KdvDepartment.fromJson(Map<String, dynamic> json) => KdvDepartment(
        kasadepid: json['kasadepid'] as int,
        name: json['name'] as String,
        kdvRate: json['kdv_rate'] as num,
      );

  String get displayLabel => '$name (%${kdvRate.toStringAsFixed(kdvRate % 1 == 0 ? 0 : 2)})';
}

/// Reverse of [matchKdvDepartment] -- given a raw KDV percentage read off a
/// supplier's price-list (bulk Excel import), finds the department with
/// that exact rate, since department (kasadepid) is what a new product
/// actually needs, not the raw percentage.
KdvDepartment? matchKdvDepartmentByRate(num? rate, List<KdvDepartment> departments) {
  if (rate == null) return null;
  for (final d in departments) {
    if (d.kdvRate == rate) return d;
  }
  return null;
}


enum ListKind { priceCheck, restock, priceChange, custom }

extension ListKindX on ListKind {
  String get dbValue => switch (this) {
        ListKind.priceCheck => 'price_check',
        ListKind.restock => 'restock',
        ListKind.priceChange => 'price_change',
        ListKind.custom => 'custom',
      };

  String get label => switch (this) {
        ListKind.priceCheck => 'Fiyat Kontrol',
        ListKind.restock => 'Stok Yenileme',
        ListKind.priceChange => 'Fiyat Değişikliği',
        ListKind.custom => 'Özel Liste',
      };

  static ListKind fromDb(String value) => switch (value) {
        'restock' => ListKind.restock,
        'price_change' => ListKind.priceChange,
        'custom' => ListKind.custom,
        _ => ListKind.priceCheck,
      };
}

class CustomField {
  final String key;
  final String label;
  final String inputType; // 'text' | 'number'

  CustomField({required this.key, required this.label, required this.inputType});

  factory CustomField.fromJson(Map<String, dynamic> json) => CustomField(
        key: json['key'] as String,
        label: json['label'] as String,
        inputType: json['input_type'] as String? ?? 'text',
      );

  Map<String, dynamic> toJson() => {'key': key, 'label': label, 'input_type': inputType};
}

/// A plain (ListKind.custom) list no longer collects arbitrary user-typed
/// fields -- it's just a set of tick boxes for which of the product's own
/// existing attributes to show on that list's item cards. Reuses
/// ProductList.fields/CustomField as storage (one CustomField per checked
/// box, keyed by one of these) purely to avoid a schema change; inputType
/// on those entries is unused.
const standardListFieldKeys = ['name', 'barcode', 'price', 'kdv'];
const standardListFieldLabels = {
  'name': 'İsim',
  'barcode': 'Barkod',
  'price': 'Fiyat',
  'kdv': 'KDV',
};
const defaultStandardListFieldKeys = {'name', 'price', 'barcode'};

class ProductList {
  final String id;
  final String name;
  final ListKind type;
  final List<CustomField> fields;
  final DateTime createdAt;

  ProductList({
    required this.id,
    required this.name,
    required this.type,
    required this.fields,
    required this.createdAt,
  });

  factory ProductList.fromJson(Map<String, dynamic> json) => ProductList(
        id: json['id'] as String,
        name: json['name'] as String,
        type: ListKindX.fromDb(json['type'] as String),
        fields: ((json['fields'] as List?) ?? [])
            .map((f) => CustomField.fromJson(f as Map<String, dynamic>))
            .toList(),
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

/// One row of the shared `activity_log` table -- every staff action that
/// touches data logs one (see DataRepo.logAction). Surfaced read-only on
/// the desktop "Ayarlar" tab so anyone can see who did what and when.
class ActivityEntry {
  final DateTime at;
  final String userName;
  final String action;
  final String? detail;

  ActivityEntry({required this.at, required this.userName, required this.action, this.detail});

  factory ActivityEntry.fromJson(Map<String, dynamic> json) => ActivityEntry(
        at: DateTime.parse(json['created_at'] as String),
        userName: (json['user_name'] as String?)?.trim().isNotEmpty == true
            ? (json['user_name'] as String).trim()
            : 'Bilinmiyor',
        action: json['action'] as String? ?? '',
        detail: (json['detail'] as String?)?.trim().isNotEmpty == true ? (json['detail'] as String).trim() : null,
      );

  /// Human-readable Turkish label for the raw action code.
  String get label => switch (action) {
        'giris_yapildi' => 'Giriş yaptı',
        'liste_olusturuldu' => 'Liste oluşturdu',
        'liste_silindi' => 'Liste sildi',
        'liste_geri_eklendi' => 'Silinen listeyi geri aldı',
        'liste_alanlari_guncellendi' => 'Liste alanlarını değiştirdi',
        'urun_listeye_eklendi' => 'Ürünü listeye ekledi',
        'urun_listeden_silindi' => 'Ürünü listeden çıkardı',
        'urun_listeye_geri_eklendi' => 'Çıkarılan ürünü geri aldı',
        'urun_guncellendi' => 'Liste ürününü düzenledi',
        'fiyat_guncelleme_istegi' => 'Fiyat değişikliği gönderdi',
        'urun_alani_guncelleme_istegi' => 'Ürün bilgisi değişikliği gönderdi',
        'kasaya_gonderildi' => 'Değişikliği kasaya gönderdi',
        'yeni_urun_istegi' => 'Yeni ürün oluşturdu',
        'urun_silme_istegi' => 'Ürün silme isteği gönderdi',
        'etiket_yazdirma_istegi' => 'Etiket yazdırdı',
        'teraziye_gonderim_istegi' => 'Teraziye liste gönderdi',
        _ => action.replaceAll('_', ' '),
      };
}

class ChatMessage {
  final String id;
  final String senderName;
  final String body;
  final DateTime createdAt;

  ChatMessage({
    required this.id,
    required this.senderName,
    required this.body,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        senderName: json['sender_name'] as String,
        body: json['body'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class ListItem {
  final String id;
  final String listId;
  final String barcode;
  final num? quantity;
  final num? newPrice;
  final String? note;
  final Map<String, dynamic> customData;
  final DateTime scannedAt;
  final Product? product;

  ListItem({
    required this.id,
    required this.listId,
    required this.barcode,
    this.quantity,
    this.newPrice,
    this.note,
    required this.customData,
    DateTime? scannedAt,
    this.product,
  }) : scannedAt = scannedAt ?? DateTime.now();

  factory ListItem.fromJson(Map<String, dynamic> json) => ListItem(
        id: json['id'] as String,
        listId: json['list_id'] as String,
        barcode: json['barcode'] as String,
        quantity: json['quantity'] as num?,
        newPrice: json['new_price'] as num?,
        note: json['note'] as String?,
        customData: (json['custom_data'] as Map?)?.cast<String, dynamic>() ?? {},
        scannedAt: json['scanned_at'] != null ? DateTime.parse(json['scanned_at'] as String) : null,
        product: json['products'] != null
            ? Product.fromJson(json['products'] as Map<String, dynamic>)
            : null,
      );
}

/// A staged product edit (name/price/unit/department), not tied to any one
/// list -- can come from a list item's pencil icon (sourceListId/Name set)
/// or directly from "Ürün Ara" search results (both null). Reviewed and
/// sent (or discarded) from the "Kasaya Gönder" tab. `id` is a deterministic
/// `barcode:field` composite key computed client-side, so staging the same
/// field twice just overwrites the one pending row.
class PendingChange {
  final String id;
  final String barcode;
  final String field;
  final String newValue;
  final String? sourceListId;
  final String? sourceListName;
  final String? requestedBy;
  final DateTime createdAt;
  final Product? product;

  PendingChange({
    required this.id,
    required this.barcode,
    required this.field,
    required this.newValue,
    this.sourceListId,
    this.sourceListName,
    this.requestedBy,
    DateTime? createdAt,
    this.product,
  }) : createdAt = createdAt ?? DateTime.now();

  static String idFor(String barcode, String field) => '$barcode:$field';

  factory PendingChange.fromJson(Map<String, dynamic> json) => PendingChange(
        id: json['id'] as String,
        barcode: json['barcode'] as String,
        field: json['field'] as String,
        newValue: json['new_value'] as String,
        sourceListId: json['source_list_id'] as String?,
        sourceListName: json['source_list_name'] as String?,
        requestedBy: json['requested_by'] as String?,
        createdAt: json['created_at'] != null ? DateTime.parse(json['created_at'] as String) : null,
      );
}

/// A new product staged for creation, waiting to be sent from the "Kasaya
/// Gönder" tab -- the create-side equivalent of [PendingChange]. Nothing
/// reaches Digisoft until it's sent (which moves it to
/// `product_create_requests`). `id` is a client-generated uuid.
class PendingProductCreate {
  final String id;
  final String barcode;
  final String stockname;
  final num price;
  final int? kasadepid;
  final num? kdvRate;
  final String? stockunit;
  final String? reyon;
  final String? requestedBy;
  final DateTime createdAt;

  PendingProductCreate({
    required this.id,
    required this.barcode,
    required this.stockname,
    required this.price,
    this.kasadepid,
    this.kdvRate,
    this.stockunit,
    this.reyon,
    this.requestedBy,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory PendingProductCreate.fromJson(Map<String, dynamic> json) => PendingProductCreate(
        id: json['id'] as String,
        barcode: json['barcode'] as String,
        stockname: json['stockname'] as String,
        price: json['price'] as num,
        kasadepid: (json['kasadepid'] as num?)?.toInt(),
        kdvRate: json['kdv_rate'] as num?,
        stockunit: json['stockunit'] as String?,
        reyon: json['reyon'] as String?,
        requestedBy: json['requested_by'] as String?,
        createdAt: json['created_at'] != null ? DateTime.parse(json['created_at'] as String) : null,
      );
}

// ===========================================================================
// Kasa (INTER_BOS POS) mirror -- read-only. The till-PC daemon's kasaSync
// module keeps these Supabase tables (kasa_*) in step with the register's
// live sales; the app only ever SELECTs. See db/2026-08-29_kasa_mirror.sql.
// ===========================================================================

/// One till receipt (BELGE). `total`/`cashTotal`/`cardTotal` etc. are the
/// register's own precomputed figures. `soldAt` is stored UTC; call
/// `.toLocal()` for display.
class KasaReceipt {
  final int id;
  final String belgeId;
  final int? registerNo;
  final int? cashierNo;
  final String? receiptType; // FIS / ZRP / XRP
  final int? receiptNo;
  final DateTime soldAt;
  final DateTime? closedAt;
  final int? zNo;
  final num? subtotal;
  final num? vatTotal;
  final num? total;
  final num? cashTotal;
  final num? cardTotal;
  final num? discountTotal;
  final num? cancelTotal;
  final bool isVoid;
  final String? note;
  final int? lineCount;
  /// Card scheme(s) used on this receipt: 'Visa' / 'Mastercard' / 'Troy' /
  /// 'Amex' / 'Karışık' / 'Kart' (unresolved), or null for a cash-only receipt.
  final String? cardBrand;

  KasaReceipt({
    required this.id,
    required this.belgeId,
    this.registerNo,
    this.cashierNo,
    this.receiptType,
    this.receiptNo,
    required this.soldAt,
    this.closedAt,
    this.zNo,
    this.subtotal,
    this.vatTotal,
    this.total,
    this.cashTotal,
    this.cardTotal,
    this.discountTotal,
    this.cancelTotal,
    this.isVoid = false,
    this.note,
    this.lineCount,
    this.cardBrand,
  });

  factory KasaReceipt.fromJson(Map<String, dynamic> j) => KasaReceipt(
        id: (j['id'] as num).toInt(),
        belgeId: j['belge_id'] as String,
        registerNo: (j['register_no'] as num?)?.toInt(),
        cashierNo: (j['cashier_no'] as num?)?.toInt(),
        receiptType: (j['receipt_type'] as String?)?.trim(),
        receiptNo: (j['receipt_no'] as num?)?.toInt(),
        soldAt: DateTime.parse(j['sold_at'] as String),
        closedAt: j['closed_at'] != null ? DateTime.parse(j['closed_at'] as String) : null,
        zNo: (j['z_no'] as num?)?.toInt(),
        subtotal: j['subtotal'] as num?,
        vatTotal: j['vat_total'] as num?,
        total: j['total'] as num?,
        cashTotal: j['cash_total'] as num?,
        cardTotal: j['card_total'] as num?,
        discountTotal: j['discount_total'] as num?,
        cancelTotal: j['cancel_total'] as num?,
        isVoid: j['is_void'] as bool? ?? false,
        note: (j['note'] as String?)?.trim().isNotEmpty == true ? (j['note'] as String).trim() : null,
        lineCount: (j['line_count'] as num?)?.toInt(),
        cardBrand: (j['card_brand'] as String?)?.trim().isNotEmpty == true ? (j['card_brand'] as String).trim() : null,
      );

  /// FIS = normal sale receipt; ZRP/XRP are report documents.
  bool get isSale => receiptType == null || receiptType == 'FIS';

  /// A meaningful payment label: cash / card (+ brand) / mixed.
  String get paymentLabel {
    final cash = cashTotal ?? 0;
    final card = cardTotal ?? 0;
    if (cash > 0 && card > 0) return 'Karışık';
    if (card > 0) return cardBrand == null || cardBrand == 'Kart' ? 'Kart' : 'Kart · $cardBrand';
    if (cash > 0) return 'Nakit';
    return '-';
  }
}

/// One line of a till receipt (HAREKET). `name` is usually null in the
/// source -- resolve it from the product catalog by [barcode].
class KasaReceiptLine {
  final int hareketId;
  final int? receiptId;
  final String belgeId;
  final int? lineNo;
  final String? lineType; // SAT (sale) / IPT (void)
  final String? barcode;
  final String? stockCode;
  final int? pluno;
  final String? name;
  final num? qty;
  final num? unitPrice;
  final num? lineTotal;
  final num? vatRate;
  final num? discountAmount;
  final DateTime? soldAt;

  KasaReceiptLine({
    required this.hareketId,
    this.receiptId,
    required this.belgeId,
    this.lineNo,
    this.lineType,
    this.barcode,
    this.stockCode,
    this.pluno,
    this.name,
    this.qty,
    this.unitPrice,
    this.lineTotal,
    this.vatRate,
    this.discountAmount,
    this.soldAt,
  });

  bool get isVoidLine => lineType == 'IPT';

  factory KasaReceiptLine.fromJson(Map<String, dynamic> j) => KasaReceiptLine(
        hareketId: (j['hareket_id'] as num).toInt(),
        receiptId: (j['receipt_id'] as num?)?.toInt(),
        belgeId: j['belge_id'] as String,
        lineNo: (j['line_no'] as num?)?.toInt(),
        lineType: (j['line_type'] as String?)?.trim(),
        barcode: (j['barcode'] as String?)?.trim(),
        stockCode: (j['stock_code'] as String?)?.trim(),
        pluno: (j['pluno'] as num?)?.toInt(),
        name: (j['name'] as String?)?.trim().isNotEmpty == true ? (j['name'] as String).trim() : null,
        qty: j['qty'] as num?,
        unitPrice: j['unit_price'] as num?,
        lineTotal: j['line_total'] as num?,
        vatRate: j['vat_rate'] as num?,
        discountAmount: j['discount_amount'] as num?,
        soldAt: j['sold_at'] != null ? DateTime.parse(j['sold_at'] as String) : null,
      );
}

/// One payment against a receipt (ODEME). [method] is the daemon's best-effort
/// classification ('nakit' / 'kart' / 'diger').
class KasaPayment {
  final int odemeId;
  final int? receiptId;
  final String belgeId;
  final String? method;
  final num? amount;
  final num? paidAmount;
  final String? cardScheme;   // Visa / Mastercard / Troy / ...
  final String? maskedPan;    // 456354******6975
  final int? installments;    // >1 only
  final String? authCode;     // Onay_No
  final String? refNo;
  final int? batchNo;
  final String? terminalNo;
  final String? buttonLabel;  // POS_KREDI button (e.g. "KREDİ KARTI")

  KasaPayment({
    required this.odemeId,
    this.receiptId,
    required this.belgeId,
    this.method,
    this.amount,
    this.paidAmount,
    this.cardScheme,
    this.maskedPan,
    this.installments,
    this.authCode,
    this.refNo,
    this.batchNo,
    this.terminalNo,
    this.buttonLabel,
  });

  factory KasaPayment.fromJson(Map<String, dynamic> j) => KasaPayment(
        odemeId: (j['odeme_id'] as num).toInt(),
        receiptId: (j['receipt_id'] as num?)?.toInt(),
        belgeId: j['belge_id'] as String,
        method: (j['method'] as String?)?.trim(),
        amount: j['amount'] as num?,
        paidAmount: j['paid_amount'] as num?,
        cardScheme: (j['card_scheme'] as String?)?.trim().isNotEmpty == true ? (j['card_scheme'] as String).trim() : null,
        maskedPan: (j['masked_pan'] as String?)?.trim().isNotEmpty == true ? (j['masked_pan'] as String).trim() : null,
        installments: (j['installments'] as num?)?.toInt(),
        authCode: (j['auth_code'] as String?)?.trim().isNotEmpty == true ? (j['auth_code'] as String).trim() : null,
        refNo: (j['ref_no'] as String?)?.trim().isNotEmpty == true ? (j['ref_no'] as String).trim() : null,
        batchNo: (j['batch_no'] as num?)?.toInt(),
        terminalNo: (j['terminal_no'] as String?)?.trim().isNotEmpty == true ? (j['terminal_no'] as String).trim() : null,
        buttonLabel: (j['button_label'] as String?)?.trim().isNotEmpty == true ? (j['button_label'] as String).trim() : null,
      );

  bool get isCard => method == 'kart' || cardScheme != null || maskedPan != null;

  String get methodLabel {
    if (isCard) return cardScheme == null ? 'Kart' : 'Kart · $cardScheme';
    return switch (method) {
      'nakit' => 'Nakit',
      _ => buttonLabel ?? 'Diğer',
    };
  }
}

/// A daily Z report row (SERVER_ZREPORT). [turnover] is the register's own
/// GIRO figure for that day.
class KasaZReport {
  final int id;
  final int? zNo;
  final DateTime? zDate;
  final num? turnover;
  final String? info;

  KasaZReport({required this.id, this.zNo, this.zDate, this.turnover, this.info});

  factory KasaZReport.fromJson(Map<String, dynamic> j) => KasaZReport(
        id: (j['id'] as num).toInt(),
        zNo: (j['z_no'] as num?)?.toInt(),
        zDate: j['z_date'] != null ? DateTime.parse(j['z_date'] as String) : null,
        turnover: j['turnover'] as num?,
        info: (j['info'] as String?)?.trim().isNotEmpty == true ? (j['info'] as String).trim() : null,
      );
}

/// One (day, barcode) sales roll-up (kasa_product_sales_daily) -- also the
/// row shape returned by the kasa_top_products RPC (sale_date omitted there).
class KasaProductSales {
  final DateTime? saleDate;
  final String barcode;
  final num qty;
  final num revenue;
  final int lineCount;
  final DateTime? lastSoldAt;
  final Product? product; // resolved from the catalog by the repo

  KasaProductSales({
    this.saleDate,
    required this.barcode,
    required this.qty,
    required this.revenue,
    required this.lineCount,
    this.lastSoldAt,
    this.product,
  });

  factory KasaProductSales.fromJson(Map<String, dynamic> j) => KasaProductSales(
        saleDate: j['sale_date'] != null ? DateTime.parse(j['sale_date'] as String) : null,
        barcode: j['barcode'] as String,
        qty: (j['qty'] as num?) ?? 0,
        revenue: (j['revenue'] as num?) ?? 0,
        lineCount: ((j['line_count'] as num?) ?? 0).toInt(),
        lastSoldAt: j['last_sold_at'] != null ? DateTime.parse(j['last_sold_at'] as String) : null,
      );

  KasaProductSales withProduct(Product? p) => KasaProductSales(
        saleDate: saleDate, barcode: barcode, qty: qty, revenue: revenue,
        lineCount: lineCount, lastSoldAt: lastSoldAt, product: p,
      );
}

/// A row from the kasa_dead_stock RPC -- a catalog product with no till sale
/// in the requested window.
class KasaDeadStockItem {
  final String barcode;
  final String stockname;
  final num? price;
  final String? depno;
  final String? stockunit;
  final DateTime? lastSoldAt;
  final int? daysSince;
  final num qtyWindow;

  KasaDeadStockItem({
    required this.barcode,
    required this.stockname,
    this.price,
    this.depno,
    this.stockunit,
    this.lastSoldAt,
    this.daysSince,
    this.qtyWindow = 0,
  });

  factory KasaDeadStockItem.fromJson(Map<String, dynamic> j) => KasaDeadStockItem(
        barcode: j['barcode'] as String,
        stockname: (j['stockname'] as String?) ?? '',
        price: j['price'] as num?,
        depno: j['depno'] as String?,
        stockunit: j['stockunit'] as String?,
        lastSoldAt: j['last_sold_at'] != null ? DateTime.parse(j['last_sold_at'] as String) : null,
        daysSince: (j['days_since'] as num?)?.toInt(),
        qtyWindow: (j['qty_window'] as num?) ?? 0,
      );
}

/// A row from kasa_product_sales_report RPC — one catalog product with its
/// aggregated sales over a user-selected date range, plus its all-time
/// last-sale info from the full PSD window (~450 days).
class KasaProductSalesReport {
  final String barcode;
  final String stockname;
  final num? price;
  final String? depno;
  final String? stockunit;
  final num? kdvRate;
  final num qty;
  final num revenue;
  final int lineCount;
  final DateTime? lastSoldAt;
  final int? daysSince;

  KasaProductSalesReport({
    required this.barcode,
    required this.stockname,
    this.price,
    this.depno,
    this.stockunit,
    this.kdvRate,
    this.qty = 0,
    this.revenue = 0,
    this.lineCount = 0,
    this.lastSoldAt,
    this.daysSince,
  });

  factory KasaProductSalesReport.fromJson(Map<String, dynamic> j) =>
      KasaProductSalesReport(
        barcode: j['barcode'] as String,
        stockname: (j['stockname'] as String?) ?? '',
        price: j['price'] as num?,
        depno: j['depno'] as String?,
        stockunit: j['stockunit'] as String?,
        kdvRate: j['kdv_rate'] as num?,
        qty: (j['qty'] as num?) ?? 0,
        revenue: (j['revenue'] as num?) ?? 0,
        lineCount: ((j['line_count'] as num?) ?? 0).toInt(),
        lastSoldAt: j['last_sold_at'] != null
            ? DateTime.parse(j['last_sold_at'] as String)
            : null,
        daysSince: (j['days_since'] as num?)?.toInt(),
      );
}

/// One day's summed qty/revenue for a barcode set -- the Kasap daily-trend
/// table. Built by client-side grouping of kasa_product_sales_daily rows,
/// not decoded from a single RPC row.
class KasaDailyTrendPoint {
  final DateTime date;
  final num qty;
  final num revenue;

  KasaDailyTrendPoint({required this.date, required this.qty, required this.revenue});
}

/// Exact receipt-level aggregate for a barcode set over a date range --
/// kasa_receipts_summary_for_barcodes RPC. Powers Kasap/Manav's Özet
/// metrics and the header line on their Son İşlemler/İptaller tabs.
class ScopedReceiptsSummary {
  final int fisSayisi;
  final num toplam;
  final num nakit;
  final num kart;
  final num indirim;
  final int iptalSayisi;
  final num iptalDeger;

  ScopedReceiptsSummary({
    required this.fisSayisi,
    required this.toplam,
    required this.nakit,
    required this.kart,
    required this.indirim,
    required this.iptalSayisi,
    required this.iptalDeger,
  });

  static final empty = ScopedReceiptsSummary(
    fisSayisi: 0,
    toplam: 0,
    nakit: 0,
    kart: 0,
    indirim: 0,
    iptalSayisi: 0,
    iptalDeger: 0,
  );

  factory ScopedReceiptsSummary.fromJson(Map<String, dynamic> j) => ScopedReceiptsSummary(
        fisSayisi: ((j['fis_sayisi'] as num?) ?? 0).toInt(),
        toplam: (j['toplam'] as num?) ?? 0,
        nakit: (j['nakit'] as num?) ?? 0,
        kart: (j['kart'] as num?) ?? 0,
        indirim: (j['indirim'] as num?) ?? 0,
        iptalSayisi: ((j['iptal_sayisi'] as num?) ?? 0).toInt(),
        iptalDeger: (j['iptal_deger'] as num?) ?? 0,
      );
}

/// Sold vs. iptal (cancelled) split for one product over a date range --
/// kasa_product_sales_void_breakdown RPC. "Iptal" covers both a whole
/// voided receipt and an individual line-level reversal (line_type='IPT').
class SalesVoidBreakdown {
  final num soldQty;
  final num soldRevenue;
  final int soldCount;
  final num voidQty;
  final num voidRevenue;
  final int voidCount;

  SalesVoidBreakdown({
    required this.soldQty,
    required this.soldRevenue,
    required this.soldCount,
    required this.voidQty,
    required this.voidRevenue,
    required this.voidCount,
  });

  factory SalesVoidBreakdown.fromJson(Map<String, dynamic> j) => SalesVoidBreakdown(
        soldQty: (j['sold_qty'] as num?) ?? 0,
        soldRevenue: (j['sold_revenue'] as num?) ?? 0,
        soldCount: ((j['sold_count'] as num?) ?? 0).toInt(),
        voidQty: (j['void_qty'] as num?) ?? 0,
        voidRevenue: (j['void_revenue'] as num?) ?? 0,
        voidCount: ((j['void_count'] as num?) ?? 0).toInt(),
      );
}

/// A detected price mismatch (kasa_price_mismatches): the till charged
/// [tillPrice] for [barcode] while the catalog said [catalogPrice].
class KasaPriceMismatch {
  final int id;
  final int hareketId;
  final String? belgeId;
  final String barcode;
  final String? name;
  final num tillPrice;
  final num catalogPrice;
  final num diff; // tillPrice - catalogPrice
  final DateTime soldAt;
  final int? receiptNo;
  final bool resolved;
  final DateTime detectedAt;

  KasaPriceMismatch({
    required this.id,
    required this.hareketId,
    this.belgeId,
    required this.barcode,
    this.name,
    required this.tillPrice,
    required this.catalogPrice,
    required this.diff,
    required this.soldAt,
    this.receiptNo,
    this.resolved = false,
    required this.detectedAt,
  });

  factory KasaPriceMismatch.fromJson(Map<String, dynamic> j) => KasaPriceMismatch(
        id: (j['id'] as num).toInt(),
        hareketId: (j['hareket_id'] as num).toInt(),
        belgeId: j['belge_id'] as String?,
        barcode: j['barcode'] as String,
        name: (j['name'] as String?)?.trim().isNotEmpty == true ? (j['name'] as String).trim() : null,
        tillPrice: j['till_price'] as num,
        catalogPrice: j['catalog_price'] as num,
        diff: j['diff'] as num,
        soldAt: DateTime.parse(j['sold_at'] as String),
        receiptNo: (j['receipt_no'] as num?)?.toInt(),
        resolved: j['resolved'] as bool? ?? false,
        detectedAt: DateTime.parse(j['detected_at'] as String),
      );

  bool get tillCheaper => diff < 0;
}

/// A staff note bound to a till receipt (kasa_receipt_notes), keyed by
/// `belge_id` so it shows wherever that receipt appears.
class KasaReceiptNote {
  final String belgeId;
  final String note;
  final String? updatedBy;
  final DateTime updatedAt;

  KasaReceiptNote({
    required this.belgeId,
    required this.note,
    this.updatedBy,
    required this.updatedAt,
  });

  factory KasaReceiptNote.fromJson(Map<String, dynamic> j) => KasaReceiptNote(
        belgeId: j['belge_id'] as String,
        note: j['note'] as String,
        updatedBy: (j['updated_by'] as String?)?.trim().isNotEmpty == true ? (j['updated_by'] as String).trim() : null,
        updatedAt: DateTime.parse(j['updated_at'] as String),
      );
}

/// Client-side aggregate of one day's receipts, for the Günlük Özet dashboard.
class KasaDaySummary {
  final DateTime day;
  final int receiptCount;
  final int voidCount;
  final num gross;         // sum of non-void FIS totals
  final num voidValue;     // sum of void FIS totals
  final num cash;
  final num card;
  final num discount;
  final num itemsSold;     // sum of line qty across non-void receipts
  final List<num> byHour;  // length 24, turnover per hour
  final Map<String, num> cardByBrand; // 'Visa' -> total, etc. (non-void card receipts)

  KasaDaySummary({
    required this.day,
    required this.receiptCount,
    required this.voidCount,
    required this.gross,
    required this.voidValue,
    required this.cash,
    required this.card,
    required this.discount,
    required this.itemsSold,
    required this.byHour,
    this.cardByBrand = const {},
  });

  num get avgBasket => receiptCount == 0 ? 0 : gross / receiptCount;

  factory KasaDaySummary.empty(DateTime day) => KasaDaySummary(
        day: day, receiptCount: 0, voidCount: 0, gross: 0, voidValue: 0,
        cash: 0, card: 0, discount: 0, itemsSold: 0, byHour: List<num>.filled(24, 0),
      );
}

/// A past send-to-kasa attempt (from either `price_update_requests` or
/// `product_field_update_requests`) that's reached a final state -- fuels
/// the "Eski Gönderilenler" history in the "Kasaya Gönder" tab.
class SentChangeRecord {
  final String barcode;
  final String? stockname;
  final String field;
  final String newValue;
  final String? oldValue;
  final String status; // 'done' | 'error'
  final String? errorMessage;
  final String? requestedBy;
  final DateTime at;

  SentChangeRecord({
    required this.barcode,
    this.stockname,
    required this.field,
    required this.newValue,
    this.oldValue,
    required this.status,
    this.errorMessage,
    this.requestedBy,
    required this.at,
  });
}
