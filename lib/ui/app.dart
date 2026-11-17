import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/service/vpn_service.dart';
import '../ui/theme/app_theme.dart';
import 'home/home_page.dart';

class UtabakoApp extends StatelessWidget {
  const UtabakoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.select<VpnService, ThemeMode>((v) => v.themeMode);
    return MaterialApp(
      title: 'Utabako',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: const HomePage(),
    );
  }
}
