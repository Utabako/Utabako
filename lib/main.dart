import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'core/service/vpn_service.dart';
import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Utabako',
    ], await rootBundle.loadString('LICENSE'));
    yield LicenseEntryWithLineBreaks([
      'libbox / native dependencies',
    ], await rootBundle.loadString('licenses/native.txt'));
    yield LicenseEntryWithLineBreaks([
      'Android dependencies',
    ], await rootBundle.loadString('licenses/android.txt'));
  });
  runApp(
    ChangeNotifierProvider(
      create: (_) => VpnService(),
      child: const UtabakoApp(),
    ),
  );
}
