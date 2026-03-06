import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/medicine_schedule.dart';

class NotificationPermissionState {
  final bool notificationsGranted;
  final bool exactAlarmGranted;

  const NotificationPermissionState({
    required this.notificationsGranted,
    required this.exactAlarmGranted,
  });
}

class NotificationService {
  // New channel ID so Android applies updated alert behavior on existing installs.
  static const String _channelId = "medicine_reminders_urgent_v2";
  static const String _channelName = "Medicine reminders (urgent)";
  static const String _channelDescription =
      "High-urgency reminders intended to behave like call alerts";

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static final NotificationDetails _defaultNotificationDetails =
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          autoCancel: false,
          ongoing: true,
          fullScreenIntent: true,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          additionalFlags: Int32List.fromList([4]),
        ),
      );

  Future<void> initialize() async {
    tz_data.initializeTimeZones();
    await _configureTimezone();

    const androidSettings = AndroidInitializationSettings(
      "@mipmap/ic_launcher",
    );
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings: initSettings);

    final androidPlugin = _androidPlugin;
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDescription,
          importance: Importance.max,
        ),
      );
    }
  }

  Future<NotificationPermissionState> ensurePermissions() async {
    var notificationsGranted = true;
    var exactAlarmGranted = true;

    final androidPlugin = _androidPlugin;
    if (androidPlugin != null) {
      final notificationPermission = await androidPlugin
          .requestNotificationsPermission();
      if (notificationPermission != null) {
        notificationsGranted = notificationPermission;
      }

      try {
        final exactPermission = await androidPlugin
            .requestExactAlarmsPermission();
        if (exactPermission != null) {
          exactAlarmGranted = exactPermission;
        }
      } catch (_) {
        exactAlarmGranted = true;
      }

      try {
        await androidPlugin.requestFullScreenIntentPermission();
      } catch (_) {}
    }

    return NotificationPermissionState(
      notificationsGranted: notificationsGranted,
      exactAlarmGranted: exactAlarmGranted,
    );
  }

  Future<void> scheduleReminders(
    MedicineSchedule schedule, {
    required bool useExactAlarms,
    int delaySeconds = 0,
  }) async {
    for (var medicineNumber = 1; medicineNumber <= 3; medicineNumber++) {
      final plan = schedule.planForMedicine(medicineNumber);
      await scheduleReminderForPlan(
        medicineNumber,
        plan,
        useExactAlarms: useExactAlarms,
        delaySeconds: delaySeconds,
      );
    }
  }

  Future<void> scheduleDailyReminders(
    MedicineSchedule schedule, {
    required bool useExactAlarms,
    int delaySeconds = 0,
  }) {
    return scheduleReminders(
      schedule,
      useExactAlarms: useExactAlarms,
      delaySeconds: delaySeconds,
    );
  }

  Future<void> cancelReminderForMedicine(int medicineNumber) async {
    await _plugin.cancel(id: _notificationId(medicineNumber));
  }

  Future<void> scheduleReminderForMedicine(
    int medicineNumber,
    DailyTime time, {
    required bool useExactAlarms,
    int delaySeconds = 0,
  }) async {
    await scheduleReminderForPlan(
      medicineNumber,
      MedicinePlan.daily(time),
      useExactAlarms: useExactAlarms,
      delaySeconds: delaySeconds,
    );
  }

  Future<void> scheduleReminderForPlan(
    int medicineNumber,
    MedicinePlan plan, {
    required bool useExactAlarms,
    int delaySeconds = 0,
  }) async {
    final normalizedDelay = delaySeconds.clamp(0, 59);
    final scheduleMode = useExactAlarms
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;

    await _plugin.cancel(id: _notificationId(medicineNumber));

    if (plan.isDaily) {
      final scheduledDate = _nextInstanceOf(
        plan.time,
        secondOffset: normalizedDelay,
      );
      await _plugin.zonedSchedule(
        id: _notificationId(medicineNumber),
        title: "Medicine $medicineNumber time",
        body: "Compartment $medicineNumber at ${plan.time.to12HourString()}",
        scheduledDate: scheduledDate,
        notificationDetails: _defaultNotificationDetails,
        payload: "medicine_$medicineNumber",
        androidScheduleMode: scheduleMode,
        matchDateTimeComponents: DateTimeComponents.time,
      );
      return;
    }

    final oneTimeDateTime = plan.oneTimeDateTime();
    if (oneTimeDateTime == null) {
      return;
    }

    var scheduledDate = _toTzDateTime(oneTimeDateTime);
    if (normalizedDelay > 0) {
      scheduledDate = scheduledDate.add(Duration(seconds: normalizedDelay));
    }
    if (!scheduledDate.isAfter(tz.TZDateTime.now(tz.local))) {
      // One-time reminder in the past should not be scheduled.
      return;
    }

    await _plugin.zonedSchedule(
      id: _notificationId(medicineNumber),
      title: "Medicine $medicineNumber time",
      body: "Compartment $medicineNumber at ${plan.time.to12HourString()}",
      scheduledDate: scheduledDate,
      notificationDetails: _defaultNotificationDetails,
      payload: "medicine_$medicineNumber",
      androidScheduleMode: scheduleMode,
      matchDateTimeComponents: null,
    );
  }

  AndroidFlutterLocalNotificationsPlugin? get _androidPlugin {
    return _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
  }

  int _notificationId(int medicineNumber) => 100 + medicineNumber;

  tz.TZDateTime _nextInstanceOf(DailyTime time, {int secondOffset = 0}) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
      0,
    );
    if (secondOffset > 0) {
      scheduled = scheduled.add(Duration(seconds: secondOffset));
    }
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  tz.TZDateTime _toTzDateTime(DateTime dateTime) {
    return tz.TZDateTime(
      tz.local,
      dateTime.year,
      dateTime.month,
      dateTime.day,
      dateTime.hour,
      dateTime.minute,
      dateTime.second,
    );
  }

  Future<void> _configureTimezone() async {
    try {
      final timezoneInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezoneInfo.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }
  }
}
