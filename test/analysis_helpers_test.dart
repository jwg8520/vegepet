import 'package:flutter_test/flutter_test.dart';
import 'package:vegepet/features/analysis/analysis_helpers.dart';
import 'package:vegepet/features/analysis/analysis_models.dart';

void main() {
  group('parseAnalysisFeedbackMemo', () {
    test('Case A: three feedbacks', () {
      expect(parseAnalysisFeedbackMemo('단백질 높이기,탄수화물 줄이기,식이섬유 줄이기'), [
        'protein_up',
        'carbohydrates_down',
        'dietary_fiber_down',
      ]);
    });

    test('Case B: two feedbacks', () {
      expect(parseAnalysisFeedbackMemo('단백질 높이기,지방 줄이기'), [
        'protein_up',
        'fat_down',
      ]);
    });

    test('Case C: one feedback', () {
      expect(parseAnalysisFeedbackMemo('탄수화물 줄이기'), ['carbohydrates_down']);
    });

    test('Case D: spaced past data', () {
      expect(parseAnalysisFeedbackMemo('단백질 높이기, 탄수화물 줄이기, 식이섬유 줄이기'), [
        'protein_up',
        'carbohydrates_down',
        'dietary_fiber_down',
      ]);
    });

    test('Case E: duplicates in row', () {
      expect(parseAnalysisFeedbackMemo('단백질 높이기,단백질 높이기,지방 줄이기'), [
        'protein_up',
        'fat_down',
      ]);
    });

    test('Case F: unknown excluded', () {
      expect(parseAnalysisFeedbackMemo('단백질 높이기,알 수 없는 피드백,지방 줄이기'), [
        'protein_up',
        'fat_down',
      ]);
    });

    test('Case I: 높이기/늘리기 alias', () {
      expect(parseAnalysisFeedbackMemo('단백질 늘리기,지방 높이기'), [
        'protein_up',
        'fat_up',
      ]);
    });
  });

  group('buildAnalysisSnapshot aggregation', () {
    test('Case G: perfect ignores memo', () {
      final snap = buildAnalysisSnapshot(
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 7),
        targetWeightKg: null,
        weightRows: const [],
        mealRows: [
          {'result_type': 'perfect', 'memo': '단백질 높이기,탄수화물 줄이기'},
        ],
      );
      expect(snap.totalFeedbackCount, 1);
      expect(snap.pieItems.single.key, kAnalysisFeedbackPerfectKey);
      expect(snap.topFeedbackItems, isEmpty);
    });

    test('Case H: uncertain excluded', () {
      final snap = buildAnalysisSnapshot(
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 7),
        targetWeightKg: null,
        weightRows: const [],
        mealRows: [
          {'result_type': 'uncertain', 'memo': '단백질 높이기'},
        ],
      );
      expect(snap.totalFeedbackCount, 0);
      expect(snap.pieItems, isEmpty);
    });

    test('spec aggregation Top3 and other', () {
      final mealRows = <Map<String, dynamic>>[
        for (var i = 0; i < 3; i++) {'result_type': 'perfect', 'memo': null},
        for (var i = 0; i < 4; i++) {'result_type': 'good', 'memo': '탄수화물 줄이기'},
        for (var i = 0; i < 2; i++) {'result_type': 'good', 'memo': '지방 높이기'},
        {'result_type': 'good', 'memo': '단백질 높이기'},
        {'result_type': 'good', 'memo': '식이섬유 높이기'},
        {'result_type': 'bad', 'memo': '단백질 줄이기'},
      ];
      final snap = buildAnalysisSnapshot(
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 31),
        targetWeightKg: 65,
        weightRows: const [],
        mealRows: mealRows,
      );
      expect(snap.totalFeedbackCount, 12);
      expect(snap.topFeedbackItems.map((e) => e.key).toList(), [
        'carbohydrates_down',
        'fat_up',
        'protein_up',
      ]);
      expect(snap.topFeedbackItems[0].count, 4);
      expect(snap.topFeedbackItems[0].percentage, 33);
      expect(snap.topFeedbackItems[1].count, 2);
      expect(snap.topFeedbackItems[1].percentage, 17);
      expect(snap.topFeedbackItems[2].count, 1);
      expect(snap.topFeedbackItems[2].percentage, 8);
      final other = snap.pieItems.firstWhere(
        (e) => e.key == kAnalysisFeedbackOtherKey,
      );
      expect(other.count, 2);
      expect(other.percentage, 17);
      final perfect = snap.pieItems.firstWhere(
        (e) => e.key == kAnalysisFeedbackPerfectKey,
      );
      expect(perfect.count, 3);
      expect(perfect.percentage, 25);
    });

    test('tie-break uses fixed priority', () {
      final snap = buildAnalysisSnapshot(
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 7),
        targetWeightKg: null,
        weightRows: const [],
        mealRows: [
          {'result_type': 'good', 'memo': '식이섬유 줄이기'},
          {'result_type': 'good', 'memo': '지방 높이기'},
          {'result_type': 'good', 'memo': '단백질 줄이기'},
          {'result_type': 'good', 'memo': '탄수화물 높이기'},
        ],
      );
      expect(snap.topFeedbackItems.map((e) => e.key).toList(), [
        'protein_down',
        'carbohydrates_up',
        'fat_up',
      ]);
      expect(snap.pieItems.last.key, kAnalysisFeedbackOtherKey);
      expect(snap.pieItems.last.count, 1);
    });

    test('empty feedback', () {
      final snap = buildAnalysisSnapshot(
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 7),
        targetWeightKg: null,
        weightRows: const [],
        mealRows: const [],
      );
      expect(snap.totalFeedbackCount, 0);
      expect(snap.pieItems, isEmpty);
      expect(snap.topFeedbackItems, isEmpty);
    });
  });

  group('date range', () {
    test('three months clamps end-of-month', () {
      final start = analysisSubtractCalendarMonths(DateTime(2026, 5, 31), 3);
      expect(start, DateTime(2026, 2, 28));
    });
  });
}
