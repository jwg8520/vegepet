enum AnalysisPeriod { sevenDays, thirtyDays, threeMonths }

class AnalysisWeightPoint {
  const AnalysisWeightPoint({required this.date, required this.weightKg});

  final DateTime date;
  final double weightKg;
}

class AnalysisFeedbackItem {
  const AnalysisFeedbackItem({
    required this.key,
    required this.count,
    required this.percentage,
  });

  final String key;
  final int count;
  final int percentage;
}

class AnalysisSnapshot {
  const AnalysisSnapshot({
    required this.weightPoints,
    required this.targetWeightKg,
    required this.startWeightKg,
    required this.currentWeightKg,
    required this.weightChangeKg,
    required this.totalFeedbackCount,
    required this.pieItems,
    required this.topFeedbackItems,
    required this.rangeStart,
    required this.rangeEnd,
  });

  final List<AnalysisWeightPoint> weightPoints;
  final double? targetWeightKg;
  final double? startWeightKg;
  final double? currentWeightKg;
  final double? weightChangeKg;
  final int totalFeedbackCount;
  final List<AnalysisFeedbackItem> pieItems;
  final List<AnalysisFeedbackItem> topFeedbackItems;
  final DateTime rangeStart;
  final DateTime rangeEnd;

  static AnalysisSnapshot empty({DateTime? rangeStart, DateTime? rangeEnd}) {
    final end = rangeEnd ?? DateTime(1970);
    final start = rangeStart ?? end;
    return AnalysisSnapshot(
      weightPoints: const <AnalysisWeightPoint>[],
      targetWeightKg: null,
      startWeightKg: null,
      currentWeightKg: null,
      weightChangeKg: null,
      totalFeedbackCount: 0,
      pieItems: const <AnalysisFeedbackItem>[],
      topFeedbackItems: const <AnalysisFeedbackItem>[],
      rangeStart: start,
      rangeEnd: end,
    );
  }
}

/// Pie / Top3 집계에 사용하는 canonical key.
const String kAnalysisFeedbackPerfectKey = 'perfect';
const String kAnalysisFeedbackOtherKey = 'other';

const List<String> kAnalysisNutrientFeedbackPriority = <String>[
  'protein_up',
  'protein_down',
  'carbohydrates_up',
  'carbohydrates_down',
  'fat_up',
  'fat_down',
  'dietary_fiber_up',
  'dietary_fiber_down',
];
