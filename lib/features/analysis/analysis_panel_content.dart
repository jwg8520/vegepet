import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vegepet/features/analysis/analysis_helpers.dart';
import 'package:vegepet/features/analysis/analysis_models.dart';
import 'package:vegepet/features/analysis/feedback_pie_chart.dart';
import 'package:vegepet/features/analysis/weight_trend_chart.dart';
import 'package:vegepet/l10n/app_localizations.dart';

/// 분석 패널 우측 상단 기간 선택 (대제목과 동일 y라인에 배치).
class AnalysisPeriodSelector extends StatelessWidget {
  const AnalysisPeriodSelector({
    super.key,
    required this.l10n,
    required this.isEnglish,
    required this.selectedPeriod,
    required this.onSelectPeriod,
  });

  final AppLocalizations l10n;
  final bool isEnglish;
  final AnalysisPeriod selectedPeriod;
  final ValueChanged<AnalysisPeriod> onSelectPeriod;

  static const double buttonHeight = 22;

  @override
  Widget build(BuildContext context) {
    final labels = <AnalysisPeriod, String>{
      AnalysisPeriod.sevenDays: l10n.analysisPeriodSevenDays,
      AnalysisPeriod.thirtyDays: l10n.analysisPeriodThirtyDays,
      AnalysisPeriod.threeMonths: l10n.analysisPeriodThreeMonths,
    };
    final textStyle = TextStyle(
      fontSize: isEnglish ? 9 : 10,
      fontWeight: FontWeight.w700,
      color: const Color(0xFF3A3A3A),
      height: 1.0,
    );

    var maxLabelW = 0.0;
    for (final label in labels.values) {
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      maxLabelW = math.max(maxLabelW, tp.width);
    }
    // 가장 긴 라벨(“3개월” / “3 months”) 기준 동일 너비.
    final buttonWidth = maxLabelW + (isEnglish ? 10 : 12);

    Widget chip(AnalysisPeriod period) {
      final selected = selectedPeriod == period;
      return SizedBox(
        width: buttonWidth,
        height: buttonHeight,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onSelectPeriod(period),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF78AFA3).withValues(alpha: 0.28)
                    : Colors.white.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected
                      ? const Color(0xFF78AFA3).withValues(alpha: 0.7)
                      : const Color(0xFFE5E5E5).withValues(alpha: 0.8),
                  width: 0.9,
                ),
              ),
              child: Text(
                labels[period]!,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                textAlign: TextAlign.center,
                style: textStyle,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.analysisRecent,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            fontSize: isEnglish ? 9 : 10,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF3A3A3A),
            height: 1.0,
          ),
        ),
        SizedBox(width: isEnglish ? 4 : 5),
        chip(AnalysisPeriod.sevenDays),
        const SizedBox(width: 4),
        chip(AnalysisPeriod.thirtyDays),
        const SizedBox(width: 4),
        chip(AnalysisPeriod.threeMonths),
      ],
    );
  }
}

class AnalysisPanelContent extends StatelessWidget {
  const AnalysisPanelContent({
    super.key,
    required this.l10n,
    required this.isEnglish,
    required this.selectedPeriod,
    required this.snapshot,
    required this.isLoading,
    required this.loadError,
    required this.onRetry,
  });

  final AppLocalizations l10n;
  final bool isEnglish;
  final AnalysisPeriod selectedPeriod;
  final AnalysisSnapshot snapshot;
  final bool isLoading;
  final String? loadError;
  final VoidCallback onRetry;

  static const double _metricLabelFontSize = 9;
  static const double _metricValueFontSize = _metricLabelFontSize + 2;

  /// 범례 숫자열 고정 폭 (우측 끝 위치 유지).
  static const double _feedbackLegendValueWidth = 72;

  /// 범례 이름 ↔ 건수·% 간격.
  static const double _feedbackLegendNameValueGap = 5;

  /// 도넛 ↔ 범례 간격.
  static const double _feedbackDonutLegendGap = 8;

  /// 도넛 하단 ↔ Top 3 간격.
  static const double _feedbackTopThreeGap = 5;

  /// Top 3 순위 행 간격.
  static const double _feedbackTopThreeRowGap = 2;

  /// Top 3 영역 최대 높이 (제목 + 최대 3행).
  static const double _feedbackTopThreeMaxHeight = 64;

  @override
  Widget build(BuildContext context) {
    return _buildBody();
  }

  Widget _buildBody() {
    if (isLoading &&
        snapshot.weightPoints.isEmpty &&
        snapshot.totalFeedbackCount == 0) {
      return Center(
        child: Text(
          l10n.analysisLoading,
          style: TextStyle(
            fontSize: isEnglish ? 10 : 11,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF5A5A5A),
          ),
        ),
      );
    }
    if (loadError != null &&
        snapshot.weightPoints.isEmpty &&
        snapshot.totalFeedbackCount == 0) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.analysisLoadFailed,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: isEnglish ? 10 : 11,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF5A5A5A),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: onRetry, child: Text(l10n.analysisRetry)),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 50, child: _buildWeightSection()),
        Container(
          width: 1,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          color: const Color(0xFF000000).withValues(alpha: 0.06),
        ),
        Expanded(flex: 50, child: _buildFeedbackSection()),
      ],
    );
  }

  Widget _buildWeightSection() {
    final hasPoints = snapshot.weightPoints.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.analysisWeightTrendTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: isEnglish ? 11 : 12,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF000000),
            height: 1.0,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: hasPoints
              ? WeightTrendChart(
                  points: snapshot.weightPoints,
                  period: selectedPeriod,
                  rangeStart: snapshot.rangeStart,
                  rangeEnd: snapshot.rangeEnd,
                  targetWeightKg: snapshot.targetWeightKg,
                  weightLegendLabel: l10n.analysisWeightLegendWeight,
                  targetLegendLabel: l10n.analysisWeightLegendTarget,
                )
              : Center(
                  child: Text(
                    l10n.analysisNoWeightData,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: isEnglish ? 9 : 10,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF6B6B6B),
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 4),
        _buildWeightMetricsRow(),
      ],
    );
  }

  Widget _buildWeightMetricsRow() {
    final startText = snapshot.startWeightKg == null
        ? '-'
        : '${formatAnalysisWeight(snapshot.startWeightKg!)}kg';
    final currentText = snapshot.currentWeightKg == null
        ? '-'
        : '${formatAnalysisWeight(snapshot.currentWeightKg!)}kg';
    final changeText = snapshot.weightChangeKg == null
        ? '-'
        : '${formatAnalysisWeightChange(snapshot.weightChangeKg!)}kg';

    final toTarget = _toTargetDisplay();

    return Row(
      children: [
        Expanded(
          child: _metricColumn(
            label: l10n.analysisWeightStart,
            value: startText,
          ),
        ),
        Expanded(
          child: _metricColumn(
            label: l10n.analysisWeightCurrent,
            value: currentText,
          ),
        ),
        Expanded(
          child: _metricColumn(
            label: l10n.analysisWeightChange,
            value: changeText,
            valueColor: snapshot.weightChangeKg == null
                ? null
                : kAnalysisWithdrawAccentColor,
          ),
        ),
        Expanded(
          child: _metricColumn(
            label: l10n.analysisWeightToTarget,
            value: toTarget.text,
            valueColor: toTarget.color,
          ),
        ),
      ],
    );
  }

  ({String text, Color? color}) _toTargetDisplay() {
    final current = snapshot.currentWeightKg;
    final target = snapshot.targetWeightKg;
    if (current == null || target == null) {
      return (text: '-', color: null);
    }
    final remaining = current - target;
    if (remaining <= 0) {
      return (
        text: l10n.analysisTargetAchieved,
        color: kAnalysisGoalAchievedColor,
      );
    }
    return (text: '+${remaining.toStringAsFixed(1)}kg', color: null);
  }

  Widget _metricColumn({
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: _metricLabelFontSize,
            fontWeight: FontWeight.w600,
            color: Color(0xFF5A5A5A),
            height: 1.0,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: _metricValueFontSize,
            fontWeight: FontWeight.w700,
            color: valueColor ?? const Color(0xFF3A3A3A),
            height: 1.0,
          ),
        ),
      ],
    );
  }

  Widget _buildFeedbackSection() {
    final hasFeedback = snapshot.totalFeedbackCount > 0;
    final colors = analysisPieColorsForItems(snapshot.pieItems);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.analysisFeedbackTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: isEnglish ? 11 : 12,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF000000),
            height: 1.0,
          ),
        ),
        if (!hasFeedback) ...[
          // 체중 빈 안내와 동일 y: 제목 아래 4 + Expanded 중앙 + 하단 요약 영역만큼 여백.
          const SizedBox(height: 4),
          Expanded(
            child: Center(
              child: Text(
                l10n.analysisNoFeedbackData,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isEnglish ? 9 : 10,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF6B6B6B),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const SizedBox(
            height: _metricLabelFontSize + 2 + _metricValueFontSize,
          ),
        ] else ...[
          const SizedBox(height: 4),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final availableH = constraints.maxHeight;
                final availableW = constraints.maxWidth;
                final donutSize = kAnalysisFeedbackDonutSize;
                // 범례 최소 폭: 긴 한국어 이름 + gap + 숫자열.
                final legendMinW = math.min(
                  availableW * 0.48,
                  math.max(
                    148.0,
                    availableW - donutSize - _feedbackDonutLegendGap - 8,
                  ),
                );
                // 도넛을 우측으로: 남는 왼쪽 여백의 일부만 사용.
                final usedW = donutSize + _feedbackDonutLegendGap + legendMinW;
                final leftover = math.max(0.0, availableW - usedW);
                final donutLeft = leftover * 0.35;
                final legendLeft =
                    donutLeft + donutSize + _feedbackDonutLegendGap;
                final donutCenterX = donutLeft + donutSize / 2;
                final topThreeTop = donutSize + _feedbackTopThreeGap;
                final topThreeHeight = math.max(
                  0.0,
                  math.min(
                    _feedbackTopThreeMaxHeight,
                    availableH - topThreeTop,
                  ),
                );
                // Top 3: 도넛 중앙 기준 약간 왼쪽에서 시작.
                final topThreeWidth = math.min(
                  220.0,
                  availableW - (donutCenterX - 40),
                );
                final topThreeLeft = (donutCenterX - topThreeWidth * 0.35)
                    .clamp(0.0, math.max(0.0, availableW - topThreeWidth))
                    .toDouble();

                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      top: 0,
                      left: donutLeft,
                      width: donutSize,
                      height: donutSize,
                      child: FeedbackPieChart(
                        items: snapshot.pieItems,
                        centerLabel: l10n.analysisFeedbackDonutTotal(
                          snapshot.totalFeedbackCount,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: legendLeft,
                      right: 0,
                      height: donutSize,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < snapshot.pieItems.length; i++)
                              Padding(
                                padding: EdgeInsets.only(
                                  bottom: i == snapshot.pieItems.length - 1
                                      ? 0
                                      : 3,
                                ),
                                child: _legendRow(
                                  color: colors[i],
                                  item: snapshot.pieItems[i],
                                  nameMaxWidth: math.max(
                                    56.0,
                                    (availableW - legendLeft) -
                                        _feedbackLegendValueWidth -
                                        _feedbackLegendNameValueGap -
                                        12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (snapshot.topFeedbackItems.isNotEmpty &&
                        topThreeHeight > 0)
                      Positioned(
                        top: topThreeTop,
                        left: topThreeLeft,
                        width: topThreeWidth,
                        height: topThreeHeight,
                        child: _buildTopThreeBlock(),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTopThreeBlock() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.analysisFeedbackTotalTopThree(snapshot.totalFeedbackCount),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: isEnglish ? 9 : 10,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF3A3A3A),
            height: 1.1,
          ),
        ),
        const SizedBox(height: 3),
        for (var i = 0; i < snapshot.topFeedbackItems.length; i++)
          Padding(
            padding: EdgeInsets.only(
              bottom: i == snapshot.topFeedbackItems.length - 1
                  ? 0
                  : _feedbackTopThreeRowGap,
            ),
            child: Text(
              '${i + 1}. ${_feedbackLabel(snapshot.topFeedbackItems[i].key)} '
              '(${l10n.analysisFeedbackCountAndPercent(snapshot.topFeedbackItems[i].count, snapshot.topFeedbackItems[i].percentage)})',
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isEnglish ? 8.5 : 9,
                fontWeight: FontWeight.w600,
                // Top 1 전체 문구: 설정 “회원 탈퇴”와 동일 색상(0xFFB92020).
                color: i == 0
                    ? kAnalysisWithdrawAccentColor
                    : const Color(0xFF4A4A4A),
                height: 1.15,
              ),
            ),
          ),
      ],
    );
  }

  Widget _legendRow({
    required Color color,
    required AnalysisFeedbackItem item,
    required double nameMaxWidth,
  }) {
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: nameMaxWidth),
                  child: Text(
                    _feedbackLabel(item.key),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      fontSize: isEnglish ? 8 : 8.5,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF3A3A3A),
                      height: 1.0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: _feedbackLegendNameValueGap),
        SizedBox(
          width: _feedbackLegendValueWidth,
          child: Text(
            l10n.analysisFeedbackLegendValue(item.count, item.percentage),
            maxLines: 1,
            softWrap: false,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isEnglish ? 8 : 8.5,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF5A5A5A),
              height: 1.0,
            ),
          ),
        ),
      ],
    );
  }

  String _feedbackLabel(String key) {
    switch (key) {
      case kAnalysisFeedbackPerfectKey:
        return l10n.analysisFeedbackPerfect;
      case kAnalysisFeedbackOtherKey:
        return l10n.analysisFeedbackOther;
      case 'protein_up':
        return l10n.analysisFeedbackProteinUp;
      case 'protein_down':
        return l10n.analysisFeedbackProteinDown;
      case 'carbohydrates_up':
        return l10n.analysisFeedbackCarbohydratesUp;
      case 'carbohydrates_down':
        return l10n.analysisFeedbackCarbohydratesDown;
      case 'fat_up':
        return l10n.analysisFeedbackFatUp;
      case 'fat_down':
        return l10n.analysisFeedbackFatDown;
      case 'dietary_fiber_up':
        return l10n.analysisFeedbackDietaryFiberUp;
      case 'dietary_fiber_down':
        return l10n.analysisFeedbackDietaryFiberDown;
      default:
        return key;
    }
  }
}
