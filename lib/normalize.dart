/// Ports src/lib/normalize.ts from the original web app. Folds Turkish
/// letters (and case variants) to a single ASCII form so search matches
/// regardless of case or the dotted/dotless I confusion -- "İ", "I", "ı",
/// "i" all fold to "i". Dart's toLowerCase() doesn't handle this correctly
/// for Turkish text, so the special letters are mapped first.
const Map<String, String> _turkishFold = {
  'İ': 'i', 'I': 'i', 'ı': 'i', 'i': 'i',
  'Ş': 's', 'ş': 's',
  'Ğ': 'g', 'ğ': 'g',
  'Ü': 'u', 'ü': 'u',
  'Ö': 'o', 'ö': 'o',
  'Ç': 'c', 'ç': 'c',
};

String normalizeTurkish(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(_turkishFold[ch] ?? ch);
  }
  return buffer
      .toString()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
