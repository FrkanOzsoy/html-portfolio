class Product {
  final String barcode;
  final String? pluno;
  final String stockname;
  final num? price;
  final String? depno;
  final String? stockunit;

  Product({
    required this.barcode,
    this.pluno,
    required this.stockname,
    this.price,
    this.depno,
    this.stockunit,
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
        barcode: json['barcode'] as String,
        pluno: json['pluno'] as String?,
        stockname: json['stockname'] as String,
        price: json['price'] as num?,
        depno: json['depno'] as String?,
        stockunit: json['stockunit'] as String?,
      );
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

class ListItem {
  final String id;
  final String listId;
  final String barcode;
  final num? quantity;
  final num? newPrice;
  final String? note;
  final Map<String, dynamic> customData;
  final Product? product;

  ListItem({
    required this.id,
    required this.listId,
    required this.barcode,
    this.quantity,
    this.newPrice,
    this.note,
    required this.customData,
    this.product,
  });

  factory ListItem.fromJson(Map<String, dynamic> json) => ListItem(
        id: json['id'] as String,
        listId: json['list_id'] as String,
        barcode: json['barcode'] as String,
        quantity: json['quantity'] as num?,
        newPrice: json['new_price'] as num?,
        note: json['note'] as String?,
        customData: (json['custom_data'] as Map?)?.cast<String, dynamic>() ?? {},
        product: json['products'] != null
            ? Product.fromJson(json['products'] as Map<String, dynamic>)
            : null,
      );
}
