import 'dart:async';

import 'package:bluetooth_classic/models/device.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/medicine_schedule.dart';
import '../services/bluetooth_service.dart';
import '../services/notification_service.dart';
import '../services/schedule_storage.dart';

enum _SyncStateType { idle, syncing, success, error }

enum _DoseStatus { done, upcoming, due }

class _NextIntake {
  final int medicineNumber;
  final DailyTime time;
  final DateTime dateTime;

  const _NextIntake({
    required this.medicineNumber,
    required this.time,
    required this.dateTime,
  });
}

class _DeviceCommandResult {
  final bool sent;
  final bool ackReceived;
  final String? errorMessage;

  const _DeviceCommandResult({
    required this.sent,
    required this.ackReceived,
    required this.errorMessage,
  });

  bool get isSuccess => sent && errorMessage == null;
}

const Duration _dueGracePeriod = Duration(seconds: 30);

class ScheduleScreen extends StatefulWidget {
  final NotificationService notificationService;
  final ScheduleStorage scheduleStorage;
  final BluetoothService bluetoothService;
  final MedicineSchedule initialSchedule;
  final DateTime? initialLastSync;

  const ScheduleScreen({
    super.key,
    required this.notificationService,
    required this.scheduleStorage,
    required this.bluetoothService,
    required this.initialSchedule,
    required this.initialLastSync,
  });

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  late MedicineSchedule _schedule;
  DateTime? _lastSync;
  bool _isConnected = false;
  bool _syncing = false;
  DateTime _now = DateTime.now();
  Map<int, bool> _takenToday = {1: false, 2: false, 3: false};
  String _takenDateKey = "";
  _SyncStateType _syncState = _SyncStateType.idle;
  String _syncStateMessage = "Ready. Tap SYNC to push schedule to device.";
  bool _useExactAlarms = true;

  Timer? _clockTimer;
  StreamSubscription<int>? _statusSubscription;
  StreamSubscription<String>? _lineSubscription;

  @override
  void initState() {
    super.initState();
    _schedule = widget.initialSchedule;
    _lastSync = widget.initialLastSync;
    _isConnected = widget.bluetoothService.isConnected;
    _takenDateKey = _dateKey(_now);
    _loadTakenStateForToday();
    _restoreLocalRemindersOnLaunch();

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _now = DateTime.now();
      });
      _refreshTakenStateIfDateChanged();
    });

    _statusSubscription = widget.bluetoothService.onDeviceStatusChanged.listen((
      status,
    ) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isConnected = status == Device.connected;
      });
    });

    _lineSubscription = widget.bluetoothService.onLineReceived.listen((line) {
      _handleDeviceLine(line);
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _statusSubscription?.cancel();
    _lineSubscription?.cancel();
    super.dispose();
  }

  Future<void> _handleDeviceLine(String rawLine) async {
    final line = rawLine.trim();
    if (!line.startsWith("EVT,")) {
      return;
    }

    final parts = line.split(",");
    if (parts.length < 2) {
      return;
    }

    final eventType = parts[1];
    if (eventType == "TAKEN" && parts.length >= 5) {
      final takenFromDevice = <int>[];
      for (var i = 0; i < 3; i++) {
        if (parts[i + 2] == "1") {
          takenFromDevice.add(i + 1);
        }
      }
      await _applyTakenEventFromDevice(takenFromDevice);
      return;
    }

    if (eventType == "REFILL" && parts.length >= 3 && mounted) {
      final state = parts[2].toUpperCase();
      final message = state == "ON"
          ? "Refill mode enabled on device."
          : "Refill mode disabled on device.";
      _setSyncState(_SyncStateType.idle, message);
      return;
    }
  }

  Future<void> _applyTakenEventFromDevice(List<int> medicines) async {
    if (medicines.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final updatedTaken = Map<int, bool>.from(_takenToday);
    var changed = false;

    for (final medicineNumber in medicines) {
      if (medicineNumber < 1 || medicineNumber > 3) {
        continue;
      }
      if (!(updatedTaken[medicineNumber] ?? false)) {
        updatedTaken[medicineNumber] = true;
        changed = true;
      }
      await widget.scheduleStorage.saveTakenStateForDate(
        now,
        medicineNumber: medicineNumber,
        taken: true,
      );

      try {
        await widget.notificationService.cancelReminderForMedicine(
          medicineNumber,
        );
        await widget.notificationService.scheduleReminderForMedicine(
          medicineNumber,
          _schedule.timeForMedicine(medicineNumber),
          useExactAlarms: _useExactAlarms,
          delaySeconds: 0,
        );
      } catch (_) {}
    }

    if (!mounted) {
      return;
    }

    if (changed) {
      setState(() {
        _takenToday = updatedTaken;
        _now = now;
      });
    }

    final label = medicines.join(", ");
    _showSnack("Device acknowledged medicine $label.");
  }

  Future<void> _restoreLocalRemindersOnLaunch() async {
    await _schedulePhoneReminders(
      showExactAlarmDialog: false,
      successMessage: null,
    );
  }

  Future<void> _pickTimeForMedicine(int medicineNumber) async {
    final current = _schedule.timeForMedicine(medicineNumber).toTimeOfDay();
    final picked = await showTimePicker(
      context: context,
      initialTime: current,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: Color(0xFF2E7D32)),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );

    if (picked == null) {
      return;
    }

    final newTime = DailyTime.fromTimeOfDay(picked);
    final updated = _schedule.withMedicineTime(medicineNumber, newTime);
    final wasDone = _takenToday[medicineNumber] ?? false;
    final shouldClearDone = wasDone && _isTimeInFutureToday(newTime);

    await widget.scheduleStorage.saveSchedule(updated);
    if (shouldClearDone) {
      await widget.scheduleStorage.saveTakenStateForDate(
        _now,
        medicineNumber: medicineNumber,
        taken: false,
      );
    }
    if (!mounted) {
      return;
    }

    setState(() {
      _schedule = updated;
      if (shouldClearDone) {
        _takenToday[medicineNumber] = false;
      }
      _syncState = _SyncStateType.idle;
      _syncStateMessage = "Schedule saved locally. Tap SYNC to update device.";
    });

    if (shouldClearDone) {
      _showSnack(
        "Medicine $medicineNumber status reset to Upcoming for today's new time.",
      );
    }

    await _schedulePhoneReminders(
      showExactAlarmDialog: false,
      successMessage: "Phone reminders updated for the new schedule.",
    );
  }

  Future<void> _resetTodaySession() async {
    for (var medicineNumber = 1; medicineNumber <= 3; medicineNumber++) {
      await widget.scheduleStorage.saveTakenStateForDate(
        _now,
        medicineNumber: medicineNumber,
        taken: false,
      );
    }

    try {
      await widget.notificationService.scheduleDailyReminders(
        _schedule,
        useExactAlarms: _useExactAlarms,
      );
    } catch (_) {}

    if (!mounted) {
      return;
    }

    setState(() {
      _takenToday = {1: false, 2: false, 3: false};
      _syncState = _SyncStateType.idle;
      _syncStateMessage = "Today's intake session has been reset.";
    });
    _showSnack("Today's medicine intake status has been reset.");
  }

  Future<void> _loadTakenStateForToday() async {
    final taken = await widget.scheduleStorage.loadTakenStateForDate(_now);
    if (!mounted) {
      return;
    }
    setState(() {
      _takenToday = taken;
      _takenDateKey = _dateKey(_now);
    });
  }

  Future<void> _refreshTakenStateIfDateChanged() async {
    final todayKey = _dateKey(_now);
    if (todayKey == _takenDateKey) {
      return;
    }
    await _loadTakenStateForToday();
  }

  Future<void> _markDoseAsTaken(int medicineNumber) async {
    if (_takenToday[medicineNumber] ?? false) {
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _takenToday[medicineNumber] = true;
    });

    await widget.scheduleStorage.saveTakenStateForDate(
      _now,
      medicineNumber: medicineNumber,
      taken: true,
    );

    try {
      await widget.notificationService.cancelReminderForMedicine(
        medicineNumber,
      );
      await widget.notificationService.scheduleReminderForMedicine(
        medicineNumber,
        _schedule.timeForMedicine(medicineNumber),
        useExactAlarms: _useExactAlarms,
        delaySeconds: 0,
      );
    } catch (_) {}

    if (!_isConnected) {
      _showSnack(
        "Medicine $medicineNumber marked as taken. "
        "Reconnect later if you also want to send close command to device.",
      );
      return;
    }

    final ackResult = await _sendDeviceCommand(
      "ACK,$medicineNumber",
      commandName: "ACK",
      requireAck: true,
      allowNoAckIfSent: true,
      timeout: const Duration(seconds: 2),
      retryOnNoResponse: false,
    );
    if (!ackResult.isSuccess) {
      _showSnack(
        "Medicine $medicineNumber marked as taken, "
        "but failed to close compartment: "
        "${ackResult.errorMessage ?? "unknown error"}",
      );
      return;
    }

    if (ackResult.ackReceived) {
      _showSnack("Medicine $medicineNumber marked as taken.");
    } else {
      _showSnack(
        "Medicine $medicineNumber marked as taken. "
        "Close command sent to device (no ACK line received).",
      );
    }
  }

  Future<bool> _schedulePhoneReminders({
    required bool showExactAlarmDialog,
    required String? successMessage,
  }) async {
    try {
      final permissionState = await widget.notificationService
          .ensurePermissions();
      if (!permissionState.notificationsGranted) {
        _setSyncState(
          _SyncStateType.error,
          "Notification permission is required to receive reminders.",
        );
        return false;
      }

      if (!permissionState.exactAlarmGranted && showExactAlarmDialog) {
        await _showExactAlarmDialog();
      }
      if (!permissionState.exactAlarmGranted) {
        _setSyncState(
          _SyncStateType.error,
          "Exact alarms are required for real-time reminders. "
          "Enable exact alarms in app settings, then tap SYNC again.",
        );
        return false;
      }

      _useExactAlarms = permissionState.exactAlarmGranted;

      await widget.notificationService.scheduleDailyReminders(
        _schedule,
        useExactAlarms: true,
      );

      if (successMessage != null) {
        _setSyncState(_SyncStateType.success, successMessage);
      }

      return true;
    } catch (_) {
      _setSyncState(
        _SyncStateType.error,
        "Failed to schedule phone reminders. Tap SYNC to try again.",
      );
      return false;
    }
  }

  Future<void> _syncSchedule() async {
    if (_syncing) {
      return;
    }

    final connectedAtStart = _isConnected;
    if (connectedAtStart) {
      final confirmed = await _confirmSyncOverwrite();
      if (!confirmed) {
        return;
      }
    }

    setState(() {
      _syncing = true;
      _syncState = _SyncStateType.syncing;
      _syncStateMessage = connectedAtStart
          ? "Syncing device and phone reminders..."
          : "Saving phone reminders...";
    });

    String? deviceSyncError;
    String? deviceSyncWarning;
    bool deviceSynced = false;
    try {
      if (connectedAtStart) {
        final deviceResult = await _syncDeviceClockAndSchedule();
        deviceSyncError = deviceResult.$1;
        deviceSyncWarning = deviceResult.$2;
        deviceSynced = deviceSyncError == null;
      }

      final remindersReady = await _schedulePhoneReminders(
        showExactAlarmDialog: true,
        successMessage: null,
      );
      if (!remindersReady) {
        if (deviceSynced) {
          _setSyncState(
            _SyncStateType.error,
            "Device synced, but phone reminders could not be updated. "
            "Check notification permissions and tap SYNC again.",
          );
        }
        return;
      }

      await widget.scheduleStorage.saveSchedule(_schedule);

      if (deviceSyncError != null) {
        _setSyncState(
          _SyncStateType.error,
          "Phone reminders are active, but $deviceSyncError",
        );
        return;
      }

      if (!connectedAtStart) {
        _setSyncState(
          _SyncStateType.success,
          "Phone reminders are active. Connect to device later to sync pillbox.",
        );
        return;
      }

      _setSyncState(
        _SyncStateType.success,
        deviceSyncWarning == null
            ? "Phone reminders active. Device synced at "
                  "${_formatDateTime(_lastSync!)}."
            : "Phone reminders active. Device synced at "
                  "${_formatDateTime(_lastSync!)}. "
                  "$deviceSyncWarning",
      );
    } catch (_) {
      _setSyncState(
        _SyncStateType.error,
        "Failed to save schedule locally. Tap SYNC to retry.",
      );
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
        });
      }
    }
  }

  Future<(String?, String?)> _syncDeviceClockAndSchedule() async {
    if (!_isConnected) {
      return (
        "device is not connected. Reconnect and tap SYNC to retry.",
        null,
      );
    }

    final now = DateTime.now();
    final timeCommand = "TIME,${_formatDate(now)},${_formatClock(now)}";
    final timeResult = await _sendDeviceCommand(
      timeCommand,
      commandName: "TIME",
      timeout: const Duration(seconds: 1),
      retryOnNoResponse: false,
    );
    if (!timeResult.isSuccess) {
      return (timeResult.errorMessage, null);
    }

    final syncResult = await _sendDeviceCommand(
      _schedule.toSyncCommand(),
      commandName: "SYNC",
    );
    if (!syncResult.isSuccess) {
      return (syncResult.errorMessage, null);
    }

    _lastSync = DateTime.now();
    await widget.scheduleStorage.saveLastSync(_lastSync!);
    final ackWarning = (!timeResult.ackReceived || !syncResult.ackReceived)
        ? "No ACK received from device for at least one command; "
              "please verify time/schedule on LCD."
        : null;
    return (null, ackWarning);
  }

  Future<_DeviceCommandResult> _sendDeviceCommand(
    String command, {
    required String commandName,
    bool requireAck = false,
    bool allowNoAckIfSent = false,
    Duration timeout = const Duration(seconds: 8),
    bool retryOnNoResponse = true,
  }) async {
    String? response;
    try {
      response = await widget.bluetoothService.sendCommandExpectingLine(
        command,
        timeout: timeout,
        retryOnNoResponse: retryOnNoResponse,
      );
    } catch (_) {
      response = null;
    }

    if (response != null) {
      if (response.startsWith("OK")) {
        return const _DeviceCommandResult(
          sent: true,
          ackReceived: true,
          errorMessage: null,
        );
      }
      return _DeviceCommandResult(
        sent: true,
        ackReceived: true,
        errorMessage: "$commandName failed ($response). Tap SYNC to retry.",
      );
    }

    final sent = await widget.bluetoothService.sendLine(command);
    if (!sent) {
      return _DeviceCommandResult(
        sent: false,
        ackReceived: false,
        errorMessage:
            "device disconnected during $commandName sync. Reconnect and tap "
            "SYNC to retry.",
      );
    }

    if (requireAck) {
      if (allowNoAckIfSent) {
        return const _DeviceCommandResult(
          sent: true,
          ackReceived: false,
          errorMessage: null,
        );
      }
      return _DeviceCommandResult(
        sent: true,
        ackReceived: false,
        errorMessage:
            "No response from device for $commandName. Keep connection active "
            "and try again.",
      );
    }

    return const _DeviceCommandResult(
      sent: true,
      ackReceived: false,
      errorMessage: null,
    );
  }

  Future<bool> _confirmSyncOverwrite() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Overwrite device schedule?"),
          content: Text(
            "This will replace the device schedule with:\n"
            "Medicine 1: ${_schedule.medicine1.to24HourString()}\n"
            "Medicine 2: ${_schedule.medicine2.to24HourString()}\n"
            "Medicine 3: ${_schedule.medicine3.to24HourString()}",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text("Overwrite"),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _showExactAlarmDialog() async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Exact alarms not enabled"),
          content: const Text(
            "Daily reminders may be delayed by the OS.\n"
            "Enable exact alarms from app settings for best reliability.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Continue"),
            ),
            TextButton(
              onPressed: () {
                openAppSettings();
                Navigator.of(context).pop();
              },
              child: const Text("Open Settings"),
            ),
          ],
        );
      },
    );
  }

  void _setSyncState(_SyncStateType state, String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _syncState = state;
      _syncStateMessage = message;
    });
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _connectionStatusText() {
    if (!_isConnected) {
      return "Not connected";
    }
    final address =
        widget.bluetoothService.lastAddress ?? BluetoothService.deviceName;
    return "Connected to $address";
  }

  _DoseStatus _doseStatus(int medicineNumber) {
    final time = _schedule.timeForMedicine(medicineNumber);
    final scheduledDateTime = DateTime(
      _now.year,
      _now.month,
      _now.day,
      time.hour,
      time.minute,
    );

    if (_takenToday[medicineNumber] ?? false) {
      return _DoseStatus.done;
    }
    if (_now.isBefore(scheduledDateTime.add(_dueGracePeriod))) {
      return _DoseStatus.upcoming;
    }
    return _DoseStatus.due;
  }

  bool _isTimeInFutureToday(DailyTime time) {
    final scheduledDateTime = DateTime(
      _now.year,
      _now.month,
      _now.day,
      time.hour,
      time.minute,
    );
    return scheduledDateTime.isAfter(_now);
  }

  _NextIntake _nextScheduledIntake() {
    _NextIntake? next;
    for (var medicineNumber = 1; medicineNumber <= 3; medicineNumber++) {
      final time = _schedule.timeForMedicine(medicineNumber);
      var scheduled = DateTime(
        _now.year,
        _now.month,
        _now.day,
        time.hour,
        time.minute,
      );
      if (!scheduled.isAfter(_now)) {
        scheduled = scheduled.add(const Duration(days: 1));
      }

      final candidate = _NextIntake(
        medicineNumber: medicineNumber,
        time: time,
        dateTime: scheduled,
      );

      if (next == null || candidate.dateTime.isBefore(next.dateTime)) {
        next = candidate;
      }
    }
    return next!;
  }

  String _formatCountdown(Duration duration) {
    final safe = duration.isNegative ? Duration.zero : duration;
    final days = safe.inDays;
    final hours = safe.inHours.remainder(24);
    final minutes = safe.inMinutes.remainder(60);
    final seconds = safe.inSeconds.remainder(60);

    if (days > 0) {
      return "${days}d ${_two(hours)}:${_two(minutes)}:${_two(seconds)}";
    }
    return "${_two(safe.inHours)}:${_two(minutes)}:${_two(seconds)}";
  }

  Color _syncMessageColor() {
    switch (_syncState) {
      case _SyncStateType.syncing:
        return const Color(0xFF0D47A1);
      case _SyncStateType.success:
        return const Color(0xFF1B5E20);
      case _SyncStateType.error:
        return const Color(0xFFB71C1C);
      case _SyncStateType.idle:
        return const Color(0xFF37474F);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            "Smart Medicine Reminder",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ),
      body: Container(
        color: const Color(0xFFEAF7EE),
        width: double.infinity,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxHeight < 700;
              final pagePadding = compact ? 10.0 : 16.0;
              final sectionGap = compact ? 8.0 : 12.0;
              final syncButtonHeight = compact ? 48.0 : 54.0;

              final content = Padding(
                padding: EdgeInsets.all(pagePadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _clockCard(compact: compact),
                    SizedBox(height: sectionGap),
                    _statusCard(compact: compact),
                    SizedBox(height: sectionGap),
                    _medicineRow(1, compact: compact),
                    _medicineRow(2, compact: compact),
                    _medicineRow(3, compact: compact),
                    SizedBox(height: compact ? 8 : 10),
                    ElevatedButton(
                      onPressed: _syncing ? null : _syncSchedule,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7D32),
                        foregroundColor: Colors.white,
                        minimumSize: Size.fromHeight(syncButtonHeight),
                      ),
                      child: _syncing
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              "SYNC / SAVE TO DEVICE",
                              style: TextStyle(
                                fontSize: compact ? 14 : 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 8),
                      const Text(
                        "Use Connect tab for Bluetooth pairing and connection.",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ],
                ),
              );

              return Align(
                alignment: Alignment.topCenter,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topCenter,
                  child: SizedBox(width: constraints.maxWidth, child: content),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _clockCard({required bool compact}) {
    final nextIntake = _nextScheduledIntake();
    final countdown = _formatCountdown(nextIntake.dateTime.difference(_now));
    final isToday = _dateKey(nextIntake.dateTime) == _dateKey(_now);
    final dayLabel = isToday ? "Today" : "Tomorrow";

    return Container(
      padding: EdgeInsets.all(compact ? 10 : 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Next Scheduled Intake",
            style: TextStyle(
              fontSize: compact ? 12 : 13,
              color: const Color(0xFF2F5F45),
            ),
          ),
          SizedBox(height: compact ? 2 : 4),
          Text(
            "Medicine ${nextIntake.medicineNumber} • ${nextIntake.time.to24HourString()} • $dayLabel",
            style: TextStyle(
              fontSize: compact ? 12 : 13,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF1F4F37),
            ),
          ),
          SizedBox(height: compact ? 2 : 4),
          Text(
            countdown,
            style: TextStyle(
              fontSize: compact ? 24 : 28,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard({required bool compact}) {
    return Container(
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _connectionStatusText(),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: compact ? 13 : 14,
                  ),
                ),
              ),
              TextButton(
                onPressed: _syncing ? null : _resetTodaySession,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 8 : 10,
                    vertical: compact ? 4 : 6,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  "Reset Today",
                  style: TextStyle(
                    fontSize: compact ? 11 : 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 3 : 4),
          Text(
            _lastSync == null
                ? "Last sync: never"
                : "Last sync: ${_formatDateTime(_lastSync!)}",
            style: TextStyle(
              color: Colors.black54,
              fontSize: compact ? 12 : 13,
            ),
          ),
          SizedBox(height: compact ? 4 : 6),
          Text(
            _syncStateMessage,
            style: TextStyle(
              color: _syncMessageColor(),
              fontWeight: FontWeight.w600,
              fontSize: compact ? 12 : 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _medicineRow(int medicineNumber, {required bool compact}) {
    final time = _schedule.timeForMedicine(medicineNumber);
    final status = _doseStatus(medicineNumber);
    final isDue = status == _DoseStatus.due;
    const dueTextColor = Color(0xFFB71C1C);

    return Container(
      margin: EdgeInsets.only(bottom: compact ? 8 : 10),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          ElevatedButton(
            onPressed: () => _pickTimeForMedicine(medicineNumber),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2E7D32),
              foregroundColor: Colors.white,
              textStyle: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: compact ? 12 : 14,
              ),
            ),
            child: const Text("SET"),
          ),
          SizedBox(width: compact ? 8 : 12),
          Expanded(
            child: Center(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    "Medicine $medicineNumber",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 14 : 16,
                      fontWeight: FontWeight.w700,
                      color: isDue ? dueTextColor : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  _statusChip(status, compact: compact),
                ],
              ),
            ),
          ),
          Text(
            time.to24HourString(),
            style: TextStyle(
              fontSize: compact ? 20 : 22,
              fontWeight: FontWeight.bold,
              color: isDue ? dueTextColor : null,
            ),
          ),
          if (status != _DoseStatus.done) ...[
            const SizedBox(width: 4),
            IconButton(
              onPressed: () => _markDoseAsTaken(medicineNumber),
              tooltip: "Mark Medicine $medicineNumber as taken",
              icon: const Icon(Icons.check_circle),
              color: const Color(0xFF1B5E20),
              splashRadius: 18,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusChip(_DoseStatus status, {required bool compact}) {
    late final String label;
    late final Color bg;
    late final Color fg;

    switch (status) {
      case _DoseStatus.done:
        label = "Done";
        bg = const Color(0xFFDFF3E4);
        fg = const Color(0xFF1B5E20);
        break;
      case _DoseStatus.upcoming:
        label = "Upcoming";
        bg = const Color(0xFFE3F2FD);
        fg = const Color(0xFF0D47A1);
        break;
      case _DoseStatus.due:
        label = "Due";
        bg = const Color(0xFFFDECEA);
        fg = const Color(0xFFB71C1C);
        break;
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: compact ? 11 : 12,
        ),
      ),
    );
  }

  String _formatDate(DateTime dateTime) {
    return "${dateTime.year.toString().padLeft(4, "0")}-"
        "${_two(dateTime.month)}-${_two(dateTime.day)}";
  }

  String _formatClock(DateTime dateTime) {
    return "${_two(dateTime.hour)}:${_two(dateTime.minute)}:${_two(dateTime.second)}";
  }

  String _formatDateTime(DateTime dateTime) {
    return "${_formatDate(dateTime)} ${_two(dateTime.hour)}:${_two(dateTime.minute)}";
  }

  String _dateKey(DateTime dateTime) {
    return "${dateTime.year.toString().padLeft(4, "0")}"
        "${_two(dateTime.month)}${_two(dateTime.day)}";
  }

  String _two(int value) => value.toString().padLeft(2, "0");
}
