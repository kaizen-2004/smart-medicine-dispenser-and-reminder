import 'package:flutter/material.dart';

enum MedicineScheduleMode { daily, oneTime }

class DailyTime {
  final int hour;
  final int minute;

  const DailyTime(this.hour, this.minute)
    : assert(hour >= 0 && hour <= 23),
      assert(minute >= 0 && minute <= 59);

  static final RegExp _hhmmPattern = RegExp(r"^\d{2}:\d{2}$");

  static DailyTime? tryParse(String value) {
    if (!_hhmmPattern.hasMatch(value)) {
      return null;
    }
    final parts = value.split(":");
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) {
      return null;
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return null;
    }
    return DailyTime(hour, minute);
  }

  factory DailyTime.fromTimeOfDay(TimeOfDay timeOfDay) {
    return DailyTime(timeOfDay.hour, timeOfDay.minute);
  }

  TimeOfDay toTimeOfDay() => TimeOfDay(hour: hour, minute: minute);

  String to24HourString() =>
      "${hour.toString().padLeft(2, "0")}:${minute.toString().padLeft(2, "0")}";

  String to12HourString() {
    final suffix = hour >= 12 ? "PM" : "AM";
    final normalizedHour = hour % 12 == 0 ? 12 : hour % 12;
    final minuteText = minute.toString().padLeft(2, "0");
    return "$normalizedHour:$minuteText $suffix";
  }

  @override
  String toString() => to24HourString();
}

class MedicinePlan {
  final MedicineScheduleMode mode;
  final DailyTime time;
  final DateTime? oneTimeDate;

  const MedicinePlan._({
    required this.mode,
    required this.time,
    required this.oneTimeDate,
  });

  factory MedicinePlan.daily(DailyTime time) {
    return MedicinePlan._(
      mode: MedicineScheduleMode.daily,
      time: time,
      oneTimeDate: null,
    );
  }

  factory MedicinePlan.oneTime({
    required DateTime date,
    required DailyTime time,
  }) {
    return MedicinePlan._(
      mode: MedicineScheduleMode.oneTime,
      time: time,
      oneTimeDate: DateTime(date.year, date.month, date.day),
    );
  }

  bool get isDaily => mode == MedicineScheduleMode.daily;
  bool get isOneTime => mode == MedicineScheduleMode.oneTime;

  DateTime? oneTimeDateTime() {
    final date = oneTimeDate;
    if (date == null) {
      return null;
    }
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  DateTime? nextOccurrence(DateTime now) {
    if (isDaily) {
      var scheduled = DateTime(
        now.year,
        now.month,
        now.day,
        time.hour,
        time.minute,
      );
      if (!scheduled.isAfter(now)) {
        scheduled = scheduled.add(const Duration(days: 1));
      }
      return scheduled;
    }

    final target = oneTimeDateTime();
    if (target == null || !target.isAfter(now)) {
      return null;
    }
    return target;
  }

  String summaryLabel() {
    if (isDaily) {
      return "Daily";
    }
    final date = oneTimeDate;
    if (date == null) {
      return "One-time";
    }
    return "One-time ${_formatDate(date)}";
  }

  String syncDescriptor() {
    if (isDaily) {
      return "D@${time.to24HourString()}";
    }

    final date = oneTimeDate;
    if (date == null) {
      return "D@${time.to24HourString()}";
    }
    return "O@${_formatDate(date)}@${time.to24HourString()}";
  }

  static String _formatDate(DateTime date) {
    final year = date.year.toString().padLeft(4, "0");
    final month = date.month.toString().padLeft(2, "0");
    final day = date.day.toString().padLeft(2, "0");
    return "$year-$month-$day";
  }
}

class MedicineSchedule {
  final MedicinePlan medicine1;
  final MedicinePlan medicine2;
  final MedicinePlan medicine3;

  const MedicineSchedule({
    required this.medicine1,
    required this.medicine2,
    required this.medicine3,
  });

  factory MedicineSchedule.defaults() {
    return MedicineSchedule(
      medicine1: MedicinePlan.daily(const DailyTime(8, 0)),
      medicine2: MedicinePlan.daily(const DailyTime(13, 0)),
      medicine3: MedicinePlan.daily(const DailyTime(20, 0)),
    );
  }

  MedicinePlan planForMedicine(int medicineNumber) {
    switch (medicineNumber) {
      case 1:
        return medicine1;
      case 2:
        return medicine2;
      case 3:
        return medicine3;
      default:
        throw ArgumentError("medicineNumber must be 1..3");
    }
  }

  DailyTime timeForMedicine(int medicineNumber) {
    return planForMedicine(medicineNumber).time;
  }

  MedicineSchedule withMedicinePlan(int medicineNumber, MedicinePlan newPlan) {
    switch (medicineNumber) {
      case 1:
        return MedicineSchedule(
          medicine1: newPlan,
          medicine2: medicine2,
          medicine3: medicine3,
        );
      case 2:
        return MedicineSchedule(
          medicine1: medicine1,
          medicine2: newPlan,
          medicine3: medicine3,
        );
      case 3:
        return MedicineSchedule(
          medicine1: medicine1,
          medicine2: medicine2,
          medicine3: newPlan,
        );
      default:
        throw ArgumentError("medicineNumber must be 1..3");
    }
  }

  bool get hasOneTimeSchedule =>
      medicine1.isOneTime || medicine2.isOneTime || medicine3.isOneTime;

  Map<String, String?> toStorageMap() {
    return {
      "medicine_1": medicine1.time.to24HourString(),
      "medicine_2": medicine2.time.to24HourString(),
      "medicine_3": medicine3.time.to24HourString(),
      "medicine_1_mode": _modeToStorage(medicine1.mode),
      "medicine_2_mode": _modeToStorage(medicine2.mode),
      "medicine_3_mode": _modeToStorage(medicine3.mode),
      "medicine_1_date": _dateToStorage(medicine1.oneTimeDate),
      "medicine_2_date": _dateToStorage(medicine2.oneTimeDate),
      "medicine_3_date": _dateToStorage(medicine3.oneTimeDate),
    };
  }

  factory MedicineSchedule.fromStorageMap(Map<String, String?> values) {
    final defaultSchedule = MedicineSchedule.defaults();
    return MedicineSchedule(
      medicine1: _planFromStorage(
        timeRaw: values["medicine_1"],
        modeRaw: values["medicine_1_mode"],
        dateRaw: values["medicine_1_date"],
        fallback: defaultSchedule.medicine1,
      ),
      medicine2: _planFromStorage(
        timeRaw: values["medicine_2"],
        modeRaw: values["medicine_2_mode"],
        dateRaw: values["medicine_2_date"],
        fallback: defaultSchedule.medicine2,
      ),
      medicine3: _planFromStorage(
        timeRaw: values["medicine_3"],
        modeRaw: values["medicine_3_mode"],
        dateRaw: values["medicine_3_date"],
        fallback: defaultSchedule.medicine3,
      ),
    );
  }

  String toSyncCommand() {
    return "SYNC2,"
        "${medicine1.syncDescriptor()},"
        "${medicine2.syncDescriptor()},"
        "${medicine3.syncDescriptor()}";
  }

  String toLegacyDailySyncCommand() {
    return "SYNC,"
        "${medicine1.time.to24HourString()},"
        "${medicine2.time.to24HourString()},"
        "${medicine3.time.to24HourString()}";
  }

  static MedicinePlan _planFromStorage({
    required String? timeRaw,
    required String? modeRaw,
    required String? dateRaw,
    required MedicinePlan fallback,
  }) {
    final parsedTime = DailyTime.tryParse(timeRaw ?? "") ?? fallback.time;
    final mode = _modeFromStorage(modeRaw);

    if (mode == MedicineScheduleMode.oneTime) {
      final parsedDate = _dateFromStorage(dateRaw);
      if (parsedDate != null) {
        return MedicinePlan.oneTime(date: parsedDate, time: parsedTime);
      }
    }

    return MedicinePlan.daily(parsedTime);
  }

  static String _modeToStorage(MedicineScheduleMode mode) {
    switch (mode) {
      case MedicineScheduleMode.daily:
        return "daily";
      case MedicineScheduleMode.oneTime:
        return "one_time";
    }
  }

  static MedicineScheduleMode _modeFromStorage(String? raw) {
    if (raw == "one_time") {
      return MedicineScheduleMode.oneTime;
    }
    return MedicineScheduleMode.daily;
  }

  static String? _dateToStorage(DateTime? date) {
    if (date == null) {
      return null;
    }
    final year = date.year.toString().padLeft(4, "0");
    final month = date.month.toString().padLeft(2, "0");
    final day = date.day.toString().padLeft(2, "0");
    return "$year-$month-$day";
  }

  static DateTime? _dateFromStorage(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      return null;
    }
    return DateTime(parsed.year, parsed.month, parsed.day);
  }
}
