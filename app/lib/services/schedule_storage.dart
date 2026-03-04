import 'package:shared_preferences/shared_preferences.dart';

import '../models/medicine_schedule.dart';

class ScheduleStorage {
  static const String _medicine1Key = "medicine_1";
  static const String _medicine2Key = "medicine_2";
  static const String _medicine3Key = "medicine_3";
  static const String _medicine1ModeKey = "medicine_1_mode";
  static const String _medicine2ModeKey = "medicine_2_mode";
  static const String _medicine3ModeKey = "medicine_3_mode";
  static const String _medicine1DateKey = "medicine_1_date";
  static const String _medicine2DateKey = "medicine_2_date";
  static const String _medicine3DateKey = "medicine_3_date";
  static const String _lastSyncIsoKey = "last_sync_iso";

  Future<MedicineSchedule> loadSchedule() async {
    final prefs = await SharedPreferences.getInstance();
    return MedicineSchedule.fromStorageMap({
      _medicine1Key: prefs.getString(_medicine1Key),
      _medicine2Key: prefs.getString(_medicine2Key),
      _medicine3Key: prefs.getString(_medicine3Key),
      _medicine1ModeKey: prefs.getString(_medicine1ModeKey),
      _medicine2ModeKey: prefs.getString(_medicine2ModeKey),
      _medicine3ModeKey: prefs.getString(_medicine3ModeKey),
      _medicine1DateKey: prefs.getString(_medicine1DateKey),
      _medicine2DateKey: prefs.getString(_medicine2DateKey),
      _medicine3DateKey: prefs.getString(_medicine3DateKey),
    });
  }

  Future<void> saveSchedule(MedicineSchedule schedule) async {
    final prefs = await SharedPreferences.getInstance();
    final map = schedule.toStorageMap();
    for (final entry in map.entries) {
      final value = entry.value;
      if (value == null || value.isEmpty) {
        await prefs.remove(entry.key);
      } else {
        await prefs.setString(entry.key, value);
      }
    }
  }

  Future<DateTime?> loadLastSync() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_lastSyncIsoKey);
    if (value == null || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  Future<void> saveLastSync(DateTime dateTime) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSyncIsoKey, dateTime.toIso8601String());
  }

  Future<Map<int, bool>> loadTakenStateForDate(DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    final dateKey = _dateKey(date);
    return {
      1: prefs.getBool("taken_${dateKey}_1") ?? false,
      2: prefs.getBool("taken_${dateKey}_2") ?? false,
      3: prefs.getBool("taken_${dateKey}_3") ?? false,
    };
  }

  Future<void> saveTakenStateForDate(
    DateTime date, {
    required int medicineNumber,
    required bool taken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final dateKey = _dateKey(date);
    await prefs.setBool("taken_${dateKey}_$medicineNumber", taken);
  }

  String _dateKey(DateTime date) {
    final year = date.year.toString().padLeft(4, "0");
    final month = date.month.toString().padLeft(2, "0");
    final day = date.day.toString().padLeft(2, "0");
    return "$year$month$day";
  }
}
