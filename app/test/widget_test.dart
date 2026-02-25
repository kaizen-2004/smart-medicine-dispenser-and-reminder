import 'package:flutter_test/flutter_test.dart';
import 'package:smart_medicine_reminder/models/medicine_schedule.dart';

void main() {
  test('DailyTime parses HH:MM correctly', () {
    final parsed = DailyTime.tryParse('08:30');

    expect(parsed, isNotNull);
    expect(parsed!.hour, 8);
    expect(parsed.minute, 30);
    expect(parsed.to24HourString(), '08:30');
  });

  test('DailyTime rejects invalid values', () {
    expect(DailyTime.tryParse('25:00'), isNull);
    expect(DailyTime.tryParse('07:99'), isNull);
    expect(DailyTime.tryParse('invalid'), isNull);
  });
}
