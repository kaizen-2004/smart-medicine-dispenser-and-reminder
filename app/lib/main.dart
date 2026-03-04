import 'package:flutter/material.dart';

import 'models/medicine_schedule.dart';
import 'screens/app_shell.dart';
import 'screens/startup_splash_screen.dart';
import 'services/bluetooth_service.dart';
import 'services/notification_service.dart';
import 'services/schedule_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final notificationService = NotificationService();
  await notificationService.initialize();

  final storage = ScheduleStorage();
  final initialSchedule = await storage.loadSchedule();
  final initialLastSync = await storage.loadLastSync();

  runApp(
    SmartMedicineReminderApp(
      notificationService: notificationService,
      storage: storage,
      initialSchedule: initialSchedule,
      initialLastSync: initialLastSync,
    ),
  );
}

class SmartMedicineReminderApp extends StatefulWidget {
  final NotificationService notificationService;
  final ScheduleStorage storage;
  final MedicineSchedule initialSchedule;
  final DateTime? initialLastSync;

  const SmartMedicineReminderApp({
    super.key,
    required this.notificationService,
    required this.storage,
    required this.initialSchedule,
    required this.initialLastSync,
  });

  @override
  State<SmartMedicineReminderApp> createState() =>
      _SmartMedicineReminderAppState();
}

class _SmartMedicineReminderAppState extends State<SmartMedicineReminderApp> {
  late final BluetoothService _bluetoothService;

  @override
  void initState() {
    super.initState();
    _bluetoothService = BluetoothService();
  }

  @override
  void dispose() {
    _bluetoothService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Smart Medicine Reminder",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF15803D),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFEAF7EE),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2E7D32),
          foregroundColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2E7D32),
            foregroundColor: Colors.white,
          ),
        ),
        useMaterial3: true,
      ),
      home: StartupSplashScreen(
        minimumDuration: const Duration(milliseconds: 5000),
        fadeInDuration: const Duration(milliseconds: 400),
        fadeOutDuration: const Duration(milliseconds: 640),
        child: AppShell(
          notificationService: widget.notificationService,
          scheduleStorage: widget.storage,
          bluetoothService: _bluetoothService,
          initialSchedule: widget.initialSchedule,
          initialLastSync: widget.initialLastSync,
        ),
      ),
    );
  }
}
