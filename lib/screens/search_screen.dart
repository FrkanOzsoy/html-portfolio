import 'dart:async';
import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/add_to_list_button.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _repo = DataRepo();
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Product> _results = [];
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _results = [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final results = await _repo.searchProducts(value);
        if (mounted) setState(() => _results = results);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              decoration: const InputDecoration(
                hintText: 'Barkod veya ürün adı yazın (örn: pınar, PINAR, 8690...)',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: Text('Aranıyor…', style: TextStyle(color: AppColors.brown400)))
                  : _controller.text.trim().isEmpty
                      ? const SizedBox.shrink()
                      : _results.isEmpty
                          ? const Center(child: Text('Sonuç bulunamadı.', style: TextStyle(color: AppColors.brown500)))
                          : ListView.separated(
                              itemCount: _results.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 8),
                              itemBuilder: (context, i) => _ResultCard(product: _results[i]),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final Product product;
  const _ResultCard({required this.product});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.creamCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.creamBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            product.stockname,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppColors.brown900),
          ),
          const SizedBox(height: 6),
          SelectableText(
            product.barcode,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.brown700),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: AppColors.brown100, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  '${product.price ?? '-'} ₺',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.brown800),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                product.stockunit ?? '-',
                style: const TextStyle(fontSize: 14, color: AppColors.brown600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AddToListButton(product: product),
        ],
      ),
    );
  }
}
