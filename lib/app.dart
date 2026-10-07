import 'package:flutter/material.dart';

import 'core/settings.dart';
import 'screens/catalog_screen.dart';
import 'screens/data_screen.dart';
import 'screens/map_screen.dart';
import 'screens/settings_screen.dart';
import 'services/feature_repository.dart';
import 'services/sync_service.dart';

/// Warna utama, sama dengan mockup.
class AppColors {
  static const green = Color(0xFF1E6B45);
  static const greenDark = Color(0xFF134A2F);
  static const greenSoft = Color(0xFFE3EFE7);
  static const orange = Color(0xFFB4531A);
  static const orangeSoft = Color(0xFFFBEBDD);
  static const blue = Color(0xFF1F5FBF);
  static const ink = Color(0xFF16201A);
  static const muted = Color(0xFF55625A);
  static const ground = Color(0xFFF3F5F1);
  static const line = Color(0xFFD9DFD8);
}

class PetaKebunApp extends StatelessWidget {
  const PetaKebunApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.green,
      primary: AppColors.green,
      secondary: AppColors.orange,
      surface: Colors.white,
    );
    return MaterialApp(
      title: 'FA Maps',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.ground,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.ink,
          elevation: 0,
          scrolledUnderElevation: 1,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autoSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _autoSync();
  }

  /// Sinkron diam-diam saat aplikasi dibuka; gagal = tidak apa-apa (offline).
  Future<void> _autoSync() async {
    if (!AppSettings.instance.autoSync) return;
    if (AppSettings.instance.serverUrl.trim().isEmpty) return;
    try {
      await SyncService.instance.syncNow();
    } catch (_) {
      // Tidak ada sinyal: data tetap aman di HP, dicoba lagi nanti.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          MapScreen(onOpenCatalog: () => setState(() => _index = 1)),
          CatalogScreen(onShowMap: () => setState(() => _index = 0)),
          const DataScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: FeatureRepository.instance,
        builder: (context, _) {
          final pending = FeatureRepository.instance.pendingCount;
          return NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
              const NavigationDestination(icon: Icon(Icons.place_outlined), selectedIcon: Icon(Icons.place), label: 'Peta'),
              const NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Peta saya'),
              NavigationDestination(
                icon: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.list_alt_outlined)),
                selectedIcon: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.list_alt)),
                label: 'Data',
              ),
              const NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Pengaturan'),
            ],
          );
        },
      ),
    );
  }
}
