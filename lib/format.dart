/// Shared "40.00 ₺" price formatting -- used in every screen and in exports
/// so the same number always reads the same way across the app.
String formatPrice(num? price) {
  if (price == null) return '-';
  return '${price.toStringAsFixed(2)} ₺';
}
