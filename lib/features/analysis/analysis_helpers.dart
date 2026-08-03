import 'package:vegepet/features/analysis/analysis_models.dart';

DateTime analysisKstToday() {
  final d = DateTime.now().toUtc().add(const Duration(hours: 9));
  return DateTime(d.year, d.month, d.day);
}

String analysisDateKey(DateTime date) {
  final m = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$m-$day';
}

DateTime? analysisParseDateKey(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.length < 10) return null;
  final parts = text.substring(0, 10).split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

DateTime analysisSubtractCalendarMonths(DateTime date, int months) {
  var y = date.year;
  var m = date.month - months;
  while (m <= 0) {
    m += 12;
    y -= 1;
  }
  final lastDay = DateTime(y, m + 1, 0).day;
  final day = date.day > lastDay ? lastDay : date.day;
  return DateTime(y, m, day);
}

({DateTime start, DateTime end}) analysisDateRangeFor(AnalysisPeriod period) {
  final end = analysisKstToday();
  switch (period) {
    case AnalysisPeriod.sevenDays:
      return (start: end.subtract(const Duration(days: 6)), end: end);
    case AnalysisPeriod.thirtyDays:
      return (start: end.subtract(const Duration(days: 29)), end: end);
    case AnalysisPeriod.threeMonths:
      return (start: analysisSubtractCalendarMonths(end, 3), end: end);
  }
}

double? analysisParseWeightKg(dynamic raw) {
  if (raw == null) return null;
  double? value;
  if (raw is num) {
    value = raw.toDouble();
  } else {
    value = double.tryParse(raw.toString().trim().replaceAll(',', '.'));
  }
  if (value == null || !value.isFinite) return null;
  if (value < 1 || value > 500) return null;
  return value;
}

String formatAnalysisWeight(double value) => value.toStringAsFixed(1);

String formatAnalysisWeightChange(double value) {
  var v = value;
  if (v.abs() < 0.05) v = 0;
  if (v > 0) return '+${v.toStringAsFixed(1)}';
  if (v < 0) return v.toStringAsFixed(1);
  return '0.0';
}

String? analysisFeedbackKeyFromStoredLabel(String label) {
  final compact = label.trim().replaceAll(RegExp(r'\s+'), '');
  switch (compact) {
    case '단백질높이기':
    case '단백질늘리기':
      return 'protein_up';
    case '단백질줄이기':
      return 'protein_down';
    case '탄수화물높이기':
    case '탄수화물늘리기':
      return 'carbohydrates_up';
    case '탄수화물줄이기':
      return 'carbohydrates_down';
    case '지방높이기':
    case '지방늘리기':
      return 'fat_up';
    case '지방줄이기':
      return 'fat_down';
    case '식이섬유높이기':
    case '식이섬유늘리기':
      return 'dietary_fiber_up';
    case '식이섬유줄이기':
      return 'dietary_fiber_down';
    default:
      return null;
  }
}

/// meal_logs.memo → canonical feedback keys (최대 3, 행 내 중복 제거).
List<String> parseAnalysisFeedbackMemo(dynamic rawMemo) {
  if (rawMemo is! String) return const <String>[];
  final memo = rawMemo.trim();
  if (memo.isEmpty) return const <String>[];

  final parsed = <String>[];
  for (final rawPart in memo.split(',')) {
    final label = rawPart.trim();
    if (label.isEmpty) continue;
    final key = analysisFeedbackKeyFromStoredLabel(label);
    if (key == null) continue;
    if (parsed.contains(key)) continue;
    parsed.add(key);
    if (parsed.length >= 3) break;
  }
  return parsed;
}

int analysisFeedbackPriorityIndex(String key) {
  final i = kAnalysisNutrientFeedbackPriority.indexOf(key);
  return i < 0 ? 999 : i;
}

List<AnalysisWeightPoint> normalizeAnalysisWeightPoints(
  List<Map<String, dynamic>> rows,
) {
  final byDate =
      <String, ({DateTime date, double weight, DateTime? updatedAt})>{};

  for (final row in rows) {
    final date = analysisParseDateKey(row['diary_date']?.toString());
    final weight = analysisParseWeightKg(row['current_weight_kg']);
    if (date == null || weight == null) continue;
    final key = analysisDateKey(date);
    DateTime? updatedAt;
    final updatedRaw = row['updated_at']?.toString();
    if (updatedRaw != null && updatedRaw.isNotEmpty) {
      updatedAt = DateTime.tryParse(updatedRaw);
    }
    final existing = byDate[key];
    if (existing == null) {
      byDate[key] = (date: date, weight: weight, updatedAt: updatedAt);
      continue;
    }
    if (updatedAt != null && existing.updatedAt != null) {
      if (updatedAt.isAfter(existing.updatedAt!)) {
        byDate[key] = (date: date, weight: weight, updatedAt: updatedAt);
      }
    } else if (updatedAt != null && existing.updatedAt == null) {
      byDate[key] = (date: date, weight: weight, updatedAt: updatedAt);
    } else {
      // updated_at 없으면 조회 순서상 나중 값으로 덮어쓴다.
      byDate[key] = (date: date, weight: weight, updatedAt: existing.updatedAt);
    }
  }

  final points =
      byDate.values
          .map((e) => AnalysisWeightPoint(date: e.date, weightKg: e.weight))
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));
  return points;
}

AnalysisSnapshot buildAnalysisSnapshot({
  required DateTime rangeStart,
  required DateTime rangeEnd,
  required double? targetWeightKg,
  required List<Map<String, dynamic>> weightRows,
  required List<Map<String, dynamic>> mealRows,
}) {
  final weightPoints = normalizeAnalysisWeightPoints(weightRows);
  double? startWeight;
  double? currentWeight;
  double? change;
  if (weightPoints.isNotEmpty) {
    startWeight = weightPoints.first.weightKg;
    currentWeight = weightPoints.last.weightKg;
    change = currentWeight - startWeight;
    if (change.abs() < 0.05) change = 0;
  }

  final nutrientCounts = <String, int>{
    for (final k in kAnalysisNutrientFeedbackPriority) k: 0,
  };
  var perfectCount = 0;

  for (final row in mealRows) {
    final resultType = row['result_type']?.toString();
    if (resultType == 'uncertain' || resultType == null) continue;
    if (resultType == 'perfect') {
      perfectCount += 1;
      continue;
    }
    if (resultType != 'good' && resultType != 'bad') continue;
    final keys = parseAnalysisFeedbackMemo(row['memo']);
    for (final key in keys) {
      nutrientCounts[key] = (nutrientCounts[key] ?? 0) + 1;
    }
  }

  final nutrientEntries =
      nutrientCounts.entries.where((e) => e.value > 0).toList()..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        final byPriority = analysisFeedbackPriorityIndex(
          a.key,
        ).compareTo(analysisFeedbackPriorityIndex(b.key));
        if (byPriority != 0) return byPriority;
        return a.key.compareTo(b.key);
      });

  final topEntries = nutrientEntries.take(3).toList();
  final topKeys = topEntries.map((e) => e.key).toSet();
  var otherCount = 0;
  for (final e in nutrientEntries) {
    if (!topKeys.contains(e.key)) otherCount += e.value;
  }

  final total =
      perfectCount + nutrientEntries.fold<int>(0, (sum, e) => sum + e.value);

  int pct(int count) {
    if (total <= 0) return 0;
    return ((count / total) * 100).round();
  }

  final pieItems = <AnalysisFeedbackItem>[];
  if (perfectCount > 0) {
    pieItems.add(
      AnalysisFeedbackItem(
        key: kAnalysisFeedbackPerfectKey,
        count: perfectCount,
        percentage: pct(perfectCount),
      ),
    );
  }
  for (final e in topEntries) {
    pieItems.add(
      AnalysisFeedbackItem(
        key: e.key,
        count: e.value,
        percentage: pct(e.value),
      ),
    );
  }
  if (otherCount > 0) {
    pieItems.add(
      AnalysisFeedbackItem(
        key: kAnalysisFeedbackOtherKey,
        count: otherCount,
        percentage: pct(otherCount),
      ),
    );
  }

  final topFeedbackItems = topEntries
      .map(
        (e) => AnalysisFeedbackItem(
          key: e.key,
          count: e.value,
          percentage: pct(e.value),
        ),
      )
      .toList();

  return AnalysisSnapshot(
    weightPoints: weightPoints,
    targetWeightKg: analysisParseWeightKg(targetWeightKg),
    startWeightKg: startWeight,
    currentWeightKg: currentWeight,
    weightChangeKg: change,
    totalFeedbackCount: total,
    pieItems: pieItems,
    topFeedbackItems: topFeedbackItems,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
  );
}

({double minY, double maxY}) analysisWeightAxisRange({
  required List<AnalysisWeightPoint> points,
  required double? targetWeightKg,
}) {
  final values = <double>[...points.map((p) => p.weightKg), ?targetWeightKg];
  if (values.isEmpty) {
    return (minY: 50, maxY: 80);
  }
  var minY = values.reduce((a, b) => a < b ? a : b);
  var maxY = values.reduce((a, b) => a > b ? a : b);
  if ((maxY - minY) < 4) {
    final mid = (minY + maxY) / 2;
    minY = mid - 2;
    maxY = mid + 2;
  } else {
    final pad = (maxY - minY) * 0.12;
    minY -= pad;
    maxY += pad;
  }
  return (minY: minY, maxY: maxY);
}
