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
  final MedicinePlan plan;
  final DateTime dateTime;

  const _NextIntake({
    required this.medicineNumber,
    required this.plan,
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
  Map<int, bool> _deviceDueToday = {1: false, 2: false, 3: false};
  final Set<int> _markingInProgress = <int>{};
  String _takenDateKey = "";
  _SyncStateType _syncState = _SyncStateType.idle;
  String _syncStateMessage = "Tap SYNC to update phone and device.";
  bool _useExactAlarms = true;
  bool _autoSyncing = false;

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
      final wasConnected = _isConnected;
      final isNowConnected = status == Device.connected;
      setState(() {
        _isConnected = isNowConnected;
      });

      if (!wasConnected && isNowConnected) {
        unawaited(_autoSyncOnReconnect());
      }
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
    if (eventType == "DUE" && parts.length >= 5 && mounted) {
      setState(() {
        for (var i = 0; i < 3; i++) {
          if (parts[i + 2] == "1") {
            _deviceDueToday[i + 1] = true;
          }
        }
        _now = DateTime.now();
      });
      return;
    }

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
      _deviceDueToday[medicineNumber] = false;
      await widget.scheduleStorage.saveTakenStateForDate(
        now,
        medicineNumber: medicineNumber,
        taken: true,
      );

      try {
        await widget.notificationService.cancelReminderForMedicine(
          medicineNumber,
        );
        final plan = _schedule.planForMedicine(medicineNumber);
        if (plan.isDaily) {
          await widget.notificationService.scheduleReminderForPlan(
            medicineNumber,
            plan,
            useExactAlarms: _useExactAlarms,
            delaySeconds: 0,
          );
        }
      } catch (_) {}
    }

    if (!mounted) {
      return;
    }

    if (!changed) {
      return;
    }

    setState(() {
      _takenToday = updatedTaken;
      _now = now;
    });

    final label = medicines.join(", ");
    _showSnack("Device acknowledged medicine $label.");
  }

  Future<void> _restoreLocalRemindersOnLaunch() async {
    await _schedulePhoneReminders(
      showExactAlarmDialog: false,
      successMessage: null,
    );
  }

  Future<void> _autoSyncOnReconnect() async {
    if (!mounted || !_isConnected || _syncing || _autoSyncing) {
      return;
    }

    setState(() {
      _autoSyncing = true;
      _syncing = true;
      _syncState = _SyncStateType.syncing;
      _syncStateMessage = "Connected. Auto-syncing device...";
    });

    try {
      final result = await _syncDeviceClockAndSchedule();
      final syncError = result.$1;
      final syncWarning = result.$2;
      if (!mounted) {
        return;
      }

      if (syncError != null) {
        _setSyncState(
          _SyncStateType.error,
          "Connected, but auto-sync failed: $syncError",
        );
        return;
      }

      final syncAt = _lastSync == null
          ? _formatDateTime(DateTime.now())
          : _formatDateTime(_lastSync!);
      _setSyncState(
        _SyncStateType.success,
        syncWarning == null
            ? "Auto-sync complete at $syncAt."
            : "Auto-sync complete at $syncAt. $syncWarning",
      );
    } finally {
      if (mounted) {
        setState(() {
          _autoSyncing = false;
          _syncing = false;
        });
      }
    }
  }

  Future<void> _configureMedicinePlan(int medicineNumber) async {
    final currentPlan = _schedule.planForMedicine(medicineNumber);
    final selectedMode = await _showScheduleTypeDialog(currentPlan.mode);
    if (selectedMode == null) {
      return;
    }
    if (!mounted) {
      return;
    }

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: currentPlan.time.toTimeOfDay(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: Color(0xFF2E7D32)),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
    if (pickedTime == null) {
      return;
    }
    if (!mounted) {
      return;
    }

    final newTime = DailyTime.fromTimeOfDay(pickedTime);
    MedicinePlan newPlan;
    if (selectedMode == MedicineScheduleMode.daily) {
      newPlan = MedicinePlan.daily(newTime);
    } else {
      final initialDate = currentPlan.oneTimeDate ?? _now;
      final pickedDate = await showDatePicker(
        context: context,
        initialDate: DateTime(
          initialDate.year,
          initialDate.month,
          initialDate.day,
        ),
        firstDate: DateTime(_now.year, _now.month, _now.day),
        lastDate: DateTime(_now.year + 5, 12, 31),
      );
      if (pickedDate == null) {
        return;
      }
      if (!mounted) {
        return;
      }

      final oneTimeDateTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        newTime.hour,
        newTime.minute,
      );
      if (!oneTimeDateTime.isAfter(DateTime.now())) {
        _setSyncState(
          _SyncStateType.error,
          "One-time schedule must be set to a future date and time.",
        );
        _showSnack("Select a future date/time for one-time schedule.");
        return;
      }
      newPlan = MedicinePlan.oneTime(date: pickedDate, time: newTime);
    }

    final updated = _schedule.withMedicinePlan(medicineNumber, newPlan);
    final wasDone = _takenToday[medicineNumber] ?? false;
    final shouldClearDone = wasDone && _isPlanInFuture(newPlan);

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
      _deviceDueToday[medicineNumber] = false;
      _syncState = _SyncStateType.idle;
      _syncStateMessage = "Saved locally. Tap SYNC to apply.";
    });

    if (shouldClearDone) {
      _showSnack(
        "Medicine $medicineNumber status reset to Upcoming for the new schedule.",
      );
    }

    await _schedulePhoneReminders(
      showExactAlarmDialog: false,
      successMessage: "Phone reminders updated for the new schedule.",
    );
  }

  Future<MedicineScheduleMode?> _showScheduleTypeDialog(
    MedicineScheduleMode currentMode,
  ) async {
    return showDialog<MedicineScheduleMode>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      height: 34,
                      width: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF7EE),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.schedule_rounded,
                        color: Color(0xFF2E7D32),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        "Schedule Type",
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _scheduleModeOption(
                  mode: MedicineScheduleMode.daily,
                  selectedMode: currentMode,
                  title: "Daily",
                  subtitle: "Repeats every day at the selected time",
                  onTap: () =>
                      Navigator.of(context).pop(MedicineScheduleMode.daily),
                ),
                const SizedBox(height: 10),
                _scheduleModeOption(
                  mode: MedicineScheduleMode.oneTime,
                  selectedMode: currentMode,
                  title: "One-time",
                  subtitle: "Runs once on a specific date and time",
                  onTap: () =>
                      Navigator.of(context).pop(MedicineScheduleMode.oneTime),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text("Cancel"),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _scheduleModeOption({
    required MedicineScheduleMode mode,
    required MedicineScheduleMode selectedMode,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final isSelected = mode == selectedMode;
    return Material(
      color: isSelected ? const Color(0xFFEAF7EE) : const Color(0xFFF7F9F8),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF2E7D32)
                  : const Color(0x1A000000),
              width: isSelected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: isSelected
                            ? const Color(0xFF1B5E20)
                            : const Color(0xFF1F2328),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF5F6368),
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                isSelected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: isSelected
                    ? const Color(0xFF2E7D32)
                    : const Color(0xFF7B858E),
                size: 28,
              ),
            ],
          ),
        ),
      ),
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
      await widget.notificationService.scheduleReminders(
        _schedule,
        useExactAlarms: _useExactAlarms,
      );
    } catch (_) {}

    if (!mounted) {
      return;
    }

    setState(() {
      _takenToday = {1: false, 2: false, 3: false};
      _deviceDueToday = {1: false, 2: false, 3: false};
      _syncState = _SyncStateType.idle;
      _syncStateMessage = "Today's status reset.";
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
    if (mounted) {
      setState(() {
        _deviceDueToday = {1: false, 2: false, 3: false};
      });
    }
    await _loadTakenStateForToday();
  }

  Future<void> _markDoseAsTaken(int medicineNumber) async {
    if (_takenToday[medicineNumber] ?? false) {
      return;
    }
    if (_markingInProgress.contains(medicineNumber)) {
      return;
    }

    final status = _doseStatus(medicineNumber);
    if (status != _DoseStatus.due) {
      _showSnack("Medicine $medicineNumber can only be marked when status is Due.");
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _markingInProgress.add(medicineNumber);
    });

    try {
      if (_isConnected) {
        final ackResult = await _sendDeviceCommand(
          "ACK,$medicineNumber",
          commandName: "ACK",
          requireAck: true,
          timeout: const Duration(seconds: 3),
          retryOnNoResponse: false,
        );
        if (!ackResult.isSuccess) {
          _showSnack(
            "Failed to close compartment for medicine $medicineNumber: "
            "${ackResult.errorMessage ?? "unknown error"}",
          );
          return;
        }
      }

      await widget.scheduleStorage.saveTakenStateForDate(
        _now,
        medicineNumber: medicineNumber,
        taken: true,
      );

      if (mounted) {
        setState(() {
          _takenToday[medicineNumber] = true;
          _deviceDueToday[medicineNumber] = false;
        });
      }

      try {
        await widget.notificationService.cancelReminderForMedicine(
          medicineNumber,
        );
        final plan = _schedule.planForMedicine(medicineNumber);
        if (plan.isDaily) {
          await widget.notificationService.scheduleReminderForPlan(
            medicineNumber,
            plan,
            useExactAlarms: _useExactAlarms,
            delaySeconds: 0,
          );
        }
      } catch (_) {}

      if (_isConnected) {
        _showSnack("Medicine $medicineNumber marked as taken.");
      } else {
        _showSnack(
          "Medicine $medicineNumber marked as taken (phone only). "
          "Connect later to sync device state.",
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _markingInProgress.remove(medicineNumber);
        });
      }
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

      await widget.notificationService.scheduleReminders(
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
          ? "Syncing phone and device..."
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
          "Phone reminders are active. Connect later to sync the pillbox.",
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
      return ("device is not connected. Reconnect and tap SYNC again.", null);
    }

    final now = DateTime.now();
    final timeCommand = "TIME,${_formatDate(now)},${_formatClock(now)}";
    final timeResult = await _sendDeviceCommand(
      timeCommand,
      commandName: "TIME",
      requireAck: true,
      timeout: const Duration(seconds: 2),
      retryOnNoResponse: false,
    );
    if (!timeResult.isSuccess) {
      return (timeResult.errorMessage, null);
    }

    final syncResult = await _sendDeviceCommand(
      _schedule.toLegacyDailySyncCommand(),
      commandName: "SYNC",
      requireAck: true,
    );
    if (!syncResult.isSuccess) {
      return (syncResult.errorMessage, null);
    }

    _lastSync = DateTime.now();
    await widget.scheduleStorage.saveLastSync(_lastSync!);
    if (_schedule.hasOneTimeSchedule) {
      return (
        null,
        "Device synced with daily fallback. Current device firmware cannot "
            "store date-based one-time schedules (hardware/firmware limitation), "
            "so one-time slots were sent as daily HH:MM times.",
      );
    }
    return (null, null);
  }

  Future<_DeviceCommandResult> _sendDeviceCommand(
    String command, {
    required String commandName,
    bool requireAck = false,
    Duration timeout = const Duration(seconds: 8),
    bool retryOnNoResponse = true,
  }) async {
    final expectedOkLine = "OK,${commandName.toUpperCase()}";
    bool matcher(String line) {
      if (line.startsWith("ERR,")) {
        return true;
      }
      if (line == "OK") {
        return true;
      }
      return line == expectedOkLine;
    }

    String? response;
    try {
      response = await widget.bluetoothService.sendCommandExpectingLine(
        command,
        timeout: timeout,
        retryOnNoResponse: retryOnNoResponse,
        acceptResponse: matcher,
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
        errorMessage: "$commandName failed ($response). Tap SYNC again.",
      );
    }

    if (!widget.bluetoothService.isConnected) {
      return _DeviceCommandResult(
        sent: false,
        ackReceived: false,
        errorMessage:
            "device disconnected during $commandName sync. Reconnect and tap "
            "SYNC again.",
      );
    }

    if (requireAck) {
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
            "Medicine 1: ${_planSummary(_schedule.medicine1)}\n"
            "Medicine 2: ${_planSummary(_schedule.medicine2)}\n"
            "Medicine 3: ${_planSummary(_schedule.medicine3)}",
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
    return _isConnected ? "Connected" : "Not Connected";
  }

  Widget _connectionBadge({required bool compact}) {
    final connected = _isConnected;
    final bg = connected ? const Color(0xFFE7F6EC) : const Color(0xFFFDEDED);
    final border = connected
        ? const Color(0x552E7D32)
        : const Color(0x55B71C1C);
    final fg = connected ? const Color(0xFF1B5E20) : const Color(0xFFB71C1C);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: fg,
            size: compact ? 15 : 17,
          ),
          SizedBox(width: compact ? 6 : 8),
          Flexible(
            child: Text(
              _connectionStatusText(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w800,
                fontSize: compact ? 12 : 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  _DoseStatus _doseStatus(int medicineNumber) {
    if (_takenToday[medicineNumber] ?? false) {
      return _DoseStatus.done;
    }
    if (_deviceDueToday[medicineNumber] ?? false) {
      return _DoseStatus.due;
    }

    final plan = _schedule.planForMedicine(medicineNumber);
    DateTime scheduledDateTime;
    if (plan.isDaily) {
      final time = plan.time;
      scheduledDateTime = DateTime(
        _now.year,
        _now.month,
        _now.day,
        time.hour,
        time.minute,
      );
    } else {
      final oneTime = plan.oneTimeDateTime();
      if (oneTime == null) {
        return _DoseStatus.upcoming;
      }
      final startOfToday = DateTime(_now.year, _now.month, _now.day);
      if (oneTime.isBefore(startOfToday)) {
        return _DoseStatus.done;
      }
      scheduledDateTime = oneTime;
    }

    if (_now.isBefore(scheduledDateTime.add(_dueGracePeriod))) {
      return _DoseStatus.upcoming;
    }
    return _DoseStatus.due;
  }

  bool _isPlanInFuture(MedicinePlan plan) {
    if (plan.isDaily) {
      final scheduledDateTime = DateTime(
        _now.year,
        _now.month,
        _now.day,
        plan.time.hour,
        plan.time.minute,
      );
      return scheduledDateTime.isAfter(_now);
    }

    final oneTime = plan.oneTimeDateTime();
    if (oneTime == null) {
      return false;
    }
    return oneTime.isAfter(_now);
  }

  _NextIntake? _nextScheduledIntake() {
    _NextIntake? next;
    for (var medicineNumber = 1; medicineNumber <= 3; medicineNumber++) {
      final plan = _schedule.planForMedicine(medicineNumber);
      final scheduled = plan.nextOccurrence(_now);
      if (scheduled == null) {
        continue;
      }

      final candidate = _NextIntake(
        medicineNumber: medicineNumber,
        plan: plan,
        dateTime: scheduled,
      );

      if (next == null || candidate.dateTime.isBefore(next.dateTime)) {
        next = candidate;
      }
    }
    return next;
  }

  List<int> _missedDoseMedicines() {
    final missed = <int>[];
    for (var medicineNumber = 1; medicineNumber <= 3; medicineNumber++) {
      if (_doseStatus(medicineNumber) == _DoseStatus.due) {
        missed.add(medicineNumber);
      }
    }
    return missed;
  }

  String _queueScheduleLabel(int medicineNumber) {
    final plan = _schedule.planForMedicine(medicineNumber);
    final timeLabel = plan.time.to12HourString();
    if (plan.isOneTime && plan.oneTimeDate != null) {
      return "$timeLabel • ${_formatDate(plan.oneTimeDate!)}";
    }
    return timeLabel;
  }

  Widget _missedDoseQueueCard(
    List<int> missedMedicines, {
    required bool compact,
  }) {
    if (missedMedicines.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x33B71C1C)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: Color(0xFFB71C1C)),
              SizedBox(width: compact ? 6 : 8),
              Text(
                "Missed Dose Queue",
                style: TextStyle(
                  fontSize: compact ? 13 : 14,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFFB71C1C),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 8 : 10),
          for (var i = 0; i < missedMedicines.length; i++) ...[
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 10,
                vertical: compact ? 6 : 8,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0x1AB71C1C)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Medicine ${missedMedicines[i]}",
                          style: TextStyle(
                            fontSize: compact ? 13 : 14,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF9C1A1A),
                          ),
                        ),
                        SizedBox(height: compact ? 1 : 2),
                        Text(
                          _queueScheduleLabel(missedMedicines[i]),
                          style: TextStyle(
                            fontSize: compact ? 11 : 12,
                            color: const Color(0xFF5F6368),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: () => _markDoseAsTaken(missedMedicines[i]),
                    style: FilledButton.styleFrom(
                      foregroundColor: const Color(0xFF1B5E20),
                      backgroundColor: const Color(0xFFE5F3E8),
                      textStyle: TextStyle(
                        fontSize: compact ? 11 : 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: const Text("Mark Taken"),
                  ),
                ],
              ),
            ),
            if (i < missedMedicines.length - 1)
              SizedBox(height: compact ? 6 : 8),
          ],
        ],
      ),
    );
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
        centerTitle: true,
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.medication_outlined, size: 18, color: Colors.white),
                SizedBox(width: 8),
                Text(
                  "Smart Medicine Reminder",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    color: Colors.white,
                  ),
                ),
              ],
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
              final compact = constraints.maxHeight < 760;
              final veryCompact = constraints.maxHeight < 640;
              final pagePadding = compact ? 8.0 : 12.0;
              final sectionGap = compact ? 8.0 : 12.0;
              final syncButtonHeight = compact ? 48.0 : 54.0;
              final missedMedicines = _missedDoseMedicines();

              final content = Padding(
                padding: EdgeInsets.all(pagePadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _clockCard(compact: compact),
                    SizedBox(height: sectionGap),
                    _statusCard(compact: compact),
                    if (missedMedicines.isNotEmpty) ...[
                      SizedBox(height: sectionGap),
                      _missedDoseQueueCard(missedMedicines, compact: compact),
                    ],
                    SizedBox(height: sectionGap),
                    _medicineRow(1, compact: compact),
                    _medicineRow(2, compact: compact),
                    _medicineRow(3, compact: compact),
                    SizedBox(height: compact ? 10 : 12),
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
                              "SYNC",
                              style: TextStyle(
                                fontSize: compact ? 14 : 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ],
                ),
              );

              if (veryCompact) {
                return Align(
                  alignment: Alignment.topCenter,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: constraints.maxWidth,
                      child: content,
                    ),
                  ),
                );
              }
              return content;
            },
          ),
        ),
      ),
    );
  }

  Widget _clockCard({required bool compact}) {
    final nextIntake = _nextScheduledIntake();
    if (nextIntake == null) {
      return Container(
        padding: EdgeInsets.all(compact ? 10 : 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          "No upcoming schedule. Set at least one future medicine time.",
          style: TextStyle(
            fontSize: compact ? 12 : 13,
            color: const Color(0xFF2F5F45),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final remaining = nextIntake.dateTime.difference(_now);
    final countdown = _formatCountdown(remaining);
    final scheduleTypeLabel = nextIntake.plan.isDaily ? "Daily" : "One-time";
    final friendlyDate = _formatFriendlyDate(nextIntake.dateTime);
    final timeLabel = nextIntake.plan.time.to12HourString();
    final hasMissedDue = _missedDoseMedicines().isNotEmpty;
    final ringProgress = hasMissedDue
        ? 1.0
        : _nextDoseProgress(nextIntake, remaining);
    final ringColor = hasMissedDue
        ? const Color(0xFFB71C1C)
        : const Color(0xFF2E7D32);
    final ringIcon = hasMissedDue
        ? Icons.warning_amber_rounded
        : Icons.access_time_filled_rounded;
    final ringLabel = hasMissedDue ? "Due" : "On track";
    final ringSize = compact ? 74.0 : 84.0;

    return Container(
      padding: EdgeInsets.all(compact ? 10 : 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Next Dose",
                  style: TextStyle(
                    fontSize: compact ? 12 : 13,
                    color: const Color(0xFF2F5F45),
                  ),
                ),
                SizedBox(height: compact ? 4 : 6),
                Text(
                  "Medicine ${nextIntake.medicineNumber} • $scheduleTypeLabel",
                  style: TextStyle(
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF1F4F37),
                  ),
                ),
                SizedBox(height: compact ? 3 : 5),
                Text(
                  "$friendlyDate · $timeLabel",
                  style: TextStyle(
                    fontSize: compact ? 12 : 13,
                    color: Colors.black87,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: compact ? 8 : 10),
                Text(
                  "Starts in",
                  style: TextStyle(
                    fontSize: compact ? 11 : 12,
                    color: Colors.black54,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: compact ? 2 : 3),
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
          ),
          SizedBox(width: compact ? 10 : 12),
          Column(
            children: [
              SizedBox(
                width: ringSize,
                height: ringSize,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: ringSize,
                      height: ringSize,
                      child: CircularProgressIndicator(
                        value: ringProgress,
                        strokeWidth: compact ? 6 : 7,
                        backgroundColor: const Color(0xFFE5ECE7),
                        valueColor: AlwaysStoppedAnimation<Color>(ringColor),
                      ),
                    ),
                    Icon(ringIcon, color: ringColor, size: compact ? 28 : 30),
                  ],
                ),
              ),
              SizedBox(height: compact ? 4 : 6),
              Text(
                ringLabel,
                style: TextStyle(
                  fontSize: compact ? 11 : 12,
                  fontWeight: FontWeight.w700,
                  color: ringColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  double _nextDoseProgress(_NextIntake nextIntake, Duration remaining) {
    if (remaining <= Duration.zero) {
      return 1.0;
    }

    Duration totalWindow;
    if (nextIntake.plan.isDaily) {
      totalWindow = const Duration(hours: 24);
    } else {
      final startOfToday = DateTime(_now.year, _now.month, _now.day);
      totalWindow = nextIntake.dateTime.difference(startOfToday);
      if (totalWindow <= Duration.zero) {
        totalWindow = const Duration(hours: 24);
      }
    }

    final elapsed = totalWindow - remaining;
    if (totalWindow.inMilliseconds <= 0) {
      return 0.0;
    }
    final progress = elapsed.inMilliseconds / totalWindow.inMilliseconds;
    if (progress.isNaN) {
      return 0.0;
    }
    return progress.clamp(0.0, 1.0);
  }

  String _formatFriendlyDate(DateTime dateTime) {
    const weekdays = <String>["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    const months = <String>[
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec",
    ];

    final weekday = weekdays[dateTime.weekday - 1];
    final month = months[dateTime.month - 1];
    return "$weekday, $month ${dateTime.day}";
  }

  Widget _statusCard({required bool compact}) {
    final resetButton = _resetTodayButton(compact: compact);
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
              Expanded(child: _connectionBadge(compact: compact)),
              SizedBox(width: compact ? 8 : 10),
              FittedBox(fit: BoxFit.scaleDown, child: resetButton),
            ],
          ),
          SizedBox(height: compact ? 6 : 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
            child: Text(
              _lastSync == null
                  ? "Last sync: never"
                  : "Last sync: ${_formatDateTime(_lastSync!)}",
              style: TextStyle(
                color: Colors.black54,
                fontSize: compact ? 12 : 13,
              ),
            ),
          ),
          SizedBox(height: compact ? 8 : 10),
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 12,
              vertical: compact ? 8 : 9,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F8F5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _syncStateMessage,
              style: TextStyle(
                color: _syncMessageColor(),
                fontWeight: FontWeight.w600,
                fontSize: compact ? 12 : 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resetTodayButton({required bool compact}) {
    return OutlinedButton.icon(
      onPressed: _syncing ? null : _resetTodaySession,
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF2E7D32),
        side: const BorderSide(color: Color(0x552E7D32)),
        backgroundColor: const Color(0x0F2E7D32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 12,
          vertical: compact ? 6 : 7,
        ),
        minimumSize: const Size(0, 0),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      icon: Icon(Icons.refresh_rounded, size: compact ? 14 : 15),
      label: Text(
        "Reset Today",
        style: TextStyle(
          fontSize: compact ? 11 : 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _medicineRow(int medicineNumber, {required bool compact}) {
    final plan = _schedule.planForMedicine(medicineNumber);
    final time = plan.time;
    final status = _doseStatus(medicineNumber);
    final isDue = status == _DoseStatus.due;
    final oneTimeDate = plan.isOneTime ? plan.oneTimeDate : null;
    const dueTextColor = Color(0xFFB71C1C);
    final setButtonWidth = compact ? 70.0 : 76.0;
    final timeColumnWidth = compact ? 92.0 : 104.0;
    final checkColumnWidth = compact ? 34.0 : 38.0;
    final rowGap = compact ? 6.0 : 8.0;

    return Container(
      margin: EdgeInsets.only(bottom: compact ? 6 : 8),
      constraints: BoxConstraints(minHeight: compact ? 82 : 90),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x1A000000), width: 0.8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: setButtonWidth,
            child: ElevatedButton(
              onPressed: () => _configureMedicinePlan(medicineNumber),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                minimumSize: Size(setButtonWidth, compact ? 38 : 40),
                padding: EdgeInsets.zero,
                textStyle: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: compact ? 11 : 13,
                ),
              ),
              child: const Text("SET"),
            ),
          ),
          SizedBox(width: rowGap),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    "Medicine $medicineNumber",
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: compact ? 13 : 15,
                      fontWeight: FontWeight.w700,
                      color: isDue ? dueTextColor : null,
                    ),
                  ),
                ),
                SizedBox(height: compact ? 1 : 2),
                Text(
                  _planLabel(plan),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 10 : 11,
                    color: Colors.black54,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: compact ? 5 : 6),
                _statusChip(status, compact: compact),
              ],
            ),
          ),
          SizedBox(width: rowGap),
          SizedBox(
            width: timeColumnWidth,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    time.to12HourString(),
                    maxLines: 1,
                    softWrap: false,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 18 : 20,
                      fontWeight: FontWeight.bold,
                      color: isDue ? dueTextColor : null,
                    ),
                  ),
                ),
                SizedBox(height: compact ? 1 : 2),
                SizedBox(
                  height: compact ? 13 : 15,
                  child: oneTimeDate == null
                      ? null
                      : Text(
                          _formatDate(oneTimeDate),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: compact ? 9 : 10,
                            color: Colors.black54,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ],
            ),
          ),
          SizedBox(width: rowGap),
          Container(
            width: checkColumnWidth,
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F7F2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Visibility(
                visible: status != _DoseStatus.done,
                maintainAnimation: true,
                maintainSize: true,
                maintainState: true,
                child: _markingInProgress.contains(medicineNumber)
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        onPressed: status == _DoseStatus.due
                            ? () => _markDoseAsTaken(medicineNumber)
                            : null,
                        tooltip: status == _DoseStatus.due
                            ? "Mark Medicine $medicineNumber as taken"
                            : "Available when status is Due",
                        icon: const Icon(Icons.check_circle),
                        color: status == _DoseStatus.due
                            ? const Color(0xFF1B5E20)
                            : const Color(0x802E7D32),
                        splashRadius: 18,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                ),
            ),
          ),
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
      alignment: Alignment.center,
      constraints: BoxConstraints(minWidth: compact ? 76 : 88),
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

  String _planLabel(MedicinePlan plan) {
    if (plan.isDaily) {
      return "Daily";
    }
    return "One-time";
  }

  String _planSummary(MedicinePlan plan) {
    if (plan.isDaily) {
      return "Daily at ${plan.time.to12HourString()}";
    }
    final date = plan.oneTimeDate;
    if (date == null) {
      return "One-time at ${plan.time.to12HourString()}";
    }
    return "One-time ${_formatDate(date)} ${plan.time.to12HourString()}";
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
