import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'screens/role_selection_screen.dart';
import 'services/auth_service.dart';
import 'services/mesh/mesh_service.dart';
import 'services/sos_service.dart';
import 'services/windows_ble_central_service.dart';
import 'state/ble_state.dart';
import 'state/emergency_state.dart';
import 'state/auth_state.dart';
import 'state/audit_log_state.dart';
import 'state/theme_controller.dart';
import 'theme/app_theme.dart';

const MethodChannel meshChannel =
    MethodChannel('disaster_communication/mesh');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The Kotlin mesh bridge exists only on Android.
  if (!kIsWeb && Platform.isAndroid) {
    try {
      final result =
          await meshChannel.invokeMethod<String>('meshStatus');

      debugPrint('Kotlin Mesh Bridge: $result');
    } catch (e) {
      debugPrint('Kotlin Mesh Bridge Error: $e');
    }
  }

  // Development/demo convenience only -- provisions the default Rescue
  // Team credential (Rescue ID "dis_comm") if none has been set yet. Never
  // overwrites a real credential; see AuthService.seedDefaultDemoCredentialsIfNeeded.
  await AuthService.instance.seedDefaultDemoCredentialsIfNeeded();

  // Long-lived state shared by screens and the BLE mesh. The audit chain,
  // this phone's SOS outbox and the console's received SOS are persisted
  // and restored here, so a restart loses nothing.
  final emergencyState = EmergencyState();
  final auditLog = AuditLogState(persist: true);
  await auditLog.load();
  MeshService.instance.bindAudit(auditLog);
  if (!kIsWeb && Platform.isAndroid) {
    await SosService.instance.bind(emergencyState, auditLog: auditLog);
  } else if (!kIsWeb && Platform.isWindows) {
    await WindowsBleCentralService.instance.bind(emergencyState, auditLog);
  }

  final themeController = ThemeController();
  await themeController.load();

  runApp(MyApp(
    emergencyState: emergencyState,
    auditLog: auditLog,
    themeController: themeController,
  ));
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, this.emergencyState, this.auditLog, this.themeController});

  /// Injected by main(); tests get fresh in-memory instances.
  final EmergencyState? emergencyState;
  final AuditLogState? auditLog;
  final ThemeController? themeController;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final EmergencyState _emergencyState = widget.emergencyState ?? EmergencyState();
  late final AuditLogState _auditLog = widget.auditLog ?? AuditLogState();
  late final ThemeController _theme = widget.themeController ?? ThemeController();

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BleState()),
        ChangeNotifierProvider.value(value: _emergencyState),
        ChangeNotifierProvider(create: (_) => AuthState()),
        ChangeNotifierProvider.value(value: _auditLog),
        ChangeNotifierProvider.value(value: _theme),
      ],
      child: Consumer<ThemeController>(
        builder: (context, theme, _) => MaterialApp(
          title: 'Disaster Response',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: theme.mode,
          home: const RoleSelectionScreen(),
        ),
      ),
    );
  }
}
