import 'package:flutter/material.dart';

import '../models/medicine_schedule.dart';
import '../services/bluetooth_service.dart';
import '../services/notification_service.dart';
import '../services/schedule_storage.dart';
import 'connect_device_screen.dart';
import 'credits_screen.dart';
import 'records_screen.dart';
import 'schedule_screen.dart';

class AppShell extends StatefulWidget {
  final NotificationService notificationService;
  final ScheduleStorage scheduleStorage;
  final BluetoothService bluetoothService;
  final MedicineSchedule initialSchedule;
  final DateTime? initialLastSync;

  const AppShell({
    super.key,
    required this.notificationService,
    required this.scheduleStorage,
    required this.bluetoothService,
    required this.initialSchedule,
    required this.initialLastSync,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  bool _connectVisited = false;
  bool _recordsVisited = false;
  bool _aboutVisited = false;
  int _recordsRefreshToken = 0;

  void _onDestinationSelected(int index) {
    setState(() {
      _selectedIndex = index;
      if (index == 1) {
        _connectVisited = true;
      }
      if (index == 2) {
        _recordsVisited = true;
        _recordsRefreshToken++;
      }
      if (index == 3) {
        _aboutVisited = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Offstage(
            offstage: _selectedIndex != 0,
            child: ScheduleScreen(
              notificationService: widget.notificationService,
              scheduleStorage: widget.scheduleStorage,
              bluetoothService: widget.bluetoothService,
              initialSchedule: widget.initialSchedule,
              initialLastSync: widget.initialLastSync,
            ),
          ),
          if (_connectVisited)
            Offstage(
              offstage: _selectedIndex != 1,
              child: ConnectDeviceScreen(
                bluetoothService: widget.bluetoothService,
              ),
            ),
          if (_recordsVisited)
            Offstage(
              offstage: _selectedIndex != 2,
              child: RecordsScreen(
                scheduleStorage: widget.scheduleStorage,
                refreshToken: _recordsRefreshToken,
              ),
            ),
          if (_aboutVisited)
            Offstage(offstage: _selectedIndex != 3, child: const AboutScreen()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.schedule_outlined),
            selectedIcon: Icon(Icons.schedule),
            label: "Schedule",
          ),
          NavigationDestination(
            icon: Icon(Icons.bluetooth_searching),
              selectedIcon: Icon(Icons.bluetooth_connected),
              label: "Connect",
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart),
              label: "Records",
            ),
          NavigationDestination(
            icon: Icon(Icons.info_outline),
            selectedIcon: Icon(Icons.info),
            label: "About",
          ),
        ],
      ),
    );
  }
}
