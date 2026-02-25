import 'package:shared_preferences/shared_preferences.dart';

import '../models/medicine_schedule.dart';

class ScheduleStorage {
  static const String _medicine1Key = "medicine_1";
  static const String _medicine2Key = "medicine_2";
  static const String _medicine3Key = "medicine_3";
  static const String _lastSyncIsoKey = "last_sync_iso";

  Future<MedicineSchedule> loadSchedule() async {
    final prefs = await SharedPreferences.getInstance();
    return MedicineSchedule.fromStorageMap({
      _medicine1Key: prefs.getString(_medicine1Key),
      _medicine2Key: prefs.getString(_medicine2Key),
      _medicine3Key: prefs.getString(_medicine3Key),
    });
  }

  Future<void> saveSchedule(MedicineSchedule schedule) async {
    final prefs = await SharedPreferences.getInstance();
    final map = schedule.toStorageMap();
    await prefs.setString(_medicine1Key, map[_medicine1Key]!);
    await prefs.setString(_medicine2Key, map[_medicine2Key]!);
    await prefs.setString(_medicine3Key, map[_medicine3Key]!);
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
