import 'package:flutter/material.dart';

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

  @override
  String toString() => to24HourString();
}

class MedicineSchedule {
  final DailyTime medicine1;
  final DailyTime medicine2;
  final DailyTime medicine3;

  const MedicineSchedule({
    required this.medicine1,
    required this.medicine2,
    required this.medicine3,
  });

  factory MedicineSchedule.defaults() {
    return const MedicineSchedule(
      medicine1: DailyTime(8, 0),
      medicine2: DailyTime(13, 0),
      medicine3: DailyTime(20, 0),
    );
  }

  DailyTime timeForMedicine(int medicineNumber) {
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

  MedicineSchedule withMedicineTime(int medicineNumber, DailyTime newTime) {
    switch (medicineNumber) {
      case 1:
        return MedicineSchedule(
          medicine1: newTime,
          medicine2: medicine2,
          medicine3: medicine3,
        );
      case 2:
        return MedicineSchedule(
          medicine1: medicine1,
          medicine2: newTime,
          medicine3: medicine3,
        );
      case 3:
        return MedicineSchedule(
          medicine1: medicine1,
          medicine2: medicine2,
          medicine3: newTime,
        );
      default:
        throw ArgumentError("medicineNumber must be 1..3");
    }
  }

  Map<String, String> toStorageMap() {
    return {
      "medicine_1": medicine1.to24HourString(),
      "medicine_2": medicine2.to24HourString(),
      "medicine_3": medicine3.to24HourString(),
    };
  }

  factory MedicineSchedule.fromStorageMap(Map<String, String?> values) {
    return MedicineSchedule(
      medicine1:
          DailyTime.tryParse(values["medicine_1"] ?? "") ?? const DailyTime(8, 0),
      medicine2: DailyTime.tryParse(values["medicine_2"] ?? "") ??
          const DailyTime(13, 0),
      medicine3: DailyTime.tryParse(values["medicine_3"] ?? "") ??
          const DailyTime(20, 0),
    );
  }

  String toSyncCommand() {
    return "SYNC,"
        "${medicine1.to24HourString()},"
        "${medicine2.to24HourString()},"
        "${medicine3.to24HourString()}";
  }
}
