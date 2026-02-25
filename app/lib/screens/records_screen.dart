import 'package:flutter/material.dart';

import '../services/schedule_storage.dart';

class _DayRecord {
  final DateTime date;
  final int takenCount;

  const _DayRecord({required this.date, required this.takenCount});
}

class RecordsScreen extends StatefulWidget {
  final ScheduleStorage scheduleStorage;
  final int refreshToken;

  const RecordsScreen({
    super.key,
    required this.scheduleStorage,
    required this.refreshToken,
  });

  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends State<RecordsScreen> {
  static const int _daysToShow = 7;

  bool _loading = true;
  List<_DayRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  void didUpdateWidget(covariant RecordsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) {
      _loadRecords();
    }
  }

  Future<void> _loadRecords() async {
    if (mounted) {
      setState(() {
        _loading = true;
      });
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final records = <_DayRecord>[];

    for (var daysAgo = _daysToShow - 1; daysAgo >= 0; daysAgo--) {
      final date = today.subtract(Duration(days: daysAgo));
      final taken = await widget.scheduleStorage.loadTakenStateForDate(date);
      var count = 0;
      for (var medicine = 1; medicine <= 3; medicine++) {
        if (taken[medicine] ?? false) {
          count++;
        }
      }
      records.add(_DayRecord(date: date, takenCount: count));
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _records = records;
      _loading = false;
    });
  }

  int get _todayTaken {
    if (_records.isEmpty) {
      return 0;
    }
    return _records.last.takenCount;
  }

  double get _averageTaken {
    if (_records.isEmpty) {
      return 0;
    }
    final total = _records.fold<int>(0, (sum, item) => sum + item.takenCount);
    return total / _records.length;
  }

  double get _adherencePercent {
    if (_records.isEmpty) {
      return 0;
    }
    final total = _records.fold<int>(0, (sum, item) => sum + item.takenCount);
    final maxTotal = _records.length * 3;
    return (total / maxTotal) * 100;
  }

  String _dayLabel(DateTime date) {
    const labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    return labels[date.weekday - 1];
  }

  Color _barColor(int takenCount) {
    switch (takenCount) {
      case 3:
        return const Color(0xFF2E7D32);
      case 2:
        return const Color(0xFF66BB6A);
      case 1:
        return const Color(0xFFF9A825);
      default:
        return const Color(0xFFEF5350);
    }
  }

  double _barHeight(int takenCount, double maxHeight) {
    final ratio = takenCount / 3;
    final height = ratio * maxHeight;
    final safeMax = maxHeight < 0 ? 0.0 : maxHeight;
    final clamped = height.clamp(4.0, safeMax);
    return clamped.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Records")),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 760;
            final pagePadding = compact ? 12.0 : 16.0;
            final sectionGap = compact ? 8.0 : 10.0;

            return Container(
              width: double.infinity,
              color: const Color(0xFFEAF7EE),
              padding: EdgeInsets.all(pagePadding),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _metricCard(
                                title: "Today",
                                value: "$_todayTaken/3",
                                compact: compact,
                              ),
                            ),
                            SizedBox(width: sectionGap),
                            Expanded(
                              child: _metricCard(
                                title: "7-Day Avg",
                                value: "${_averageTaken.toStringAsFixed(1)}/3",
                                compact: compact,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: sectionGap),
                        _metricCard(
                          title: "Adherence",
                          value: "${_adherencePercent.toStringAsFixed(0)}%",
                          compact: compact,
                        ),
                        SizedBox(height: compact ? 10 : 12),
                        Expanded(
                          child: Container(
                            padding: EdgeInsets.all(compact ? 10 : 12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "Daily Intake (Last 7 Days)",
                                  style: TextStyle(
                                    fontSize: compact ? 15 : 16,
                                    fontWeight: FontWeight.w800,
                                    color: const Color(0xFF1B5E20),
                                  ),
                                ),
                                SizedBox(height: compact ? 4 : 6),
                                Text(
                                  "Bars show how many medicines were marked as taken each day.",
                                  style: TextStyle(
                                    fontSize: compact ? 11 : 12,
                                    color: Colors.black54,
                                  ),
                                ),
                                SizedBox(height: compact ? 8 : 12),
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, barBounds) {
                                      final isTight = barBounds.maxHeight < 190;
                                      final reservedHeight = isTight
                                          ? 46.0
                                          : compact
                                          ? 52.0
                                          : 56.0;
                                      final maxBarHeight =
                                          barBounds.maxHeight - reservedHeight;

                                      return Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: _records
                                            .map(
                                              (record) => Expanded(
                                                child: Column(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.end,
                                                  children: [
                                                    FittedBox(
                                                      fit: BoxFit.scaleDown,
                                                      child: Text(
                                                        "${record.takenCount}/3",
                                                        style: TextStyle(
                                                          fontSize: isTight
                                                              ? 10
                                                              : 11,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                    ),
                                                    SizedBox(
                                                      height: isTight ? 2 : 4,
                                                    ),
                                                    Align(
                                                      alignment: Alignment
                                                          .bottomCenter,
                                                      child: Container(
                                                        width: isTight
                                                            ? 18
                                                            : 20,
                                                        height: _barHeight(
                                                          record.takenCount,
                                                          maxBarHeight,
                                                        ),
                                                        decoration: BoxDecoration(
                                                          color: _barColor(
                                                            record.takenCount,
                                                          ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                6,
                                                              ),
                                                        ),
                                                      ),
                                                    ),
                                                    SizedBox(
                                                      height: isTight ? 4 : 6,
                                                    ),
                                                    FittedBox(
                                                      fit: BoxFit.scaleDown,
                                                      child: Text(
                                                        _dayLabel(record.date),
                                                        style: TextStyle(
                                                          fontSize: isTight
                                                              ? 10
                                                              : 11,
                                                          color: Colors.black54,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            )
                                            .toList(),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _metricCard({
    required String title,
    required String value,
    required bool compact,
  }) {
    return Container(
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: compact ? 12 : 13,
              color: const Color(0xFF2F5F45),
            ),
          ),
          SizedBox(height: compact ? 2 : 3),
          Text(
            value,
            style: TextStyle(
              fontSize: compact ? 20 : 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
