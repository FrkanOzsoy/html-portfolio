import 'package:flutter/material.dart';
import '../data_repo.dart';
import '../theme.dart';
import 'login_screen.dart';
import 'scanner_screen.dart';
import 'search_screen.dart';
import 'lists_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final _repo = DataRepo();

  static const _titles = ['Tarayıcı', 'Ürün Ara', 'Listelerim'];

  Future<void> _signOut() async {
    await _repo.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('📦', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Text(_titles[_index]),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
            tooltip: 'Çıkış',
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: const [
          ScannerScreen(),
          SearchScreen(),
          ListsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: AppColors.brown900,
        indicatorColor: AppColors.terracotta,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected) ? Colors.white : AppColors.brown300,
          ),
        ),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner, color: AppColors.brown300),
            selectedIcon: Icon(Icons.qr_code_scanner, color: Colors.white),
            label: 'Tarayıcı',
          ),
          NavigationDestination(
            icon: Icon(Icons.search, color: AppColors.brown300),
            selectedIcon: Icon(Icons.search, color: Colors.white),
            label: 'Ürün Ara',
          ),
          NavigationDestination(
            icon: Icon(Icons.list_alt, color: AppColors.brown300),
            selectedIcon: Icon(Icons.list_alt, color: Colors.white),
            label: 'Listelerim',
          ),
        ],
      ),
    );
  }
}
