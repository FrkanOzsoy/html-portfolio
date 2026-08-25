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
