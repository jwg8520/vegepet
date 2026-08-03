import 'package:flutter/material.dart';
import 'package:vegepet/features/analysis/analysis_helpers.dart';
import 'package:vegepet/features/analysis/analysis_models.dart';
import 'package:vegepet/features/analysis/feedback_pie_chart.dart';
import 'package:vegepet/features/analysis/weight_trend_chart.dart';
import 'package:vegepet/l10n/app_localizations.dart';

class AnalysisPanelContent extends StatelessWidget {
  const AnalysisPanelContent({
    super.key,
    required this.l10n,
    required this.isEnglish,
    required this.selectedPeriod,
    required this.snapshot,
    required this.isLoading,
    required this.loadError,
    required this.onSelectPeriod,
    required this.onRetry,
  });

  final AppLocalizations l10n;
  final bool isEnglish;
  final AnalysisPeriod selectedPeriod;
  final AnalysisSnapshot snapshot;
  final bool isLoading;
  final String? loadError;
  final ValueChanged<AnalysisPeriod> onSelectPeriod;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPeriodSelector(),
        const SizedBox(height: 6),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildPeriodSelector() {
    Widget chip(AnalysisPeriod period, String label) {
      final selected = selectedPeriod == period;
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onSelectPeriod(period),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF78AFA3).withValues(alpha: 0.28)
                    : Colors.white.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? const Color(0xFF78AFA3).withValues(alpha: 0.7)
                      : const Color(0xFFE5E5E5).withValues(alpha: 0.8),
                  width: 0.9,
                ),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: isEnglish ? 9 : 10,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF3A3A3A),
                  height: 1.0,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip(AnalysisPeriod.sevenDays, l10n.analysisPeriodSevenDays),
        const SizedBox(width: 6),
        chip(AnalysisPeriod.thirtyDays, l10n.analysisPeriodThirtyDays),
        const SizedBox(width: 6),
        chip(AnalysisPeriod.threeMonths, l10n.analysisPeriodThreeMonths),
      ],
    );
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
        Text(
          _weightSummaryLine(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: isEnglish ? 8.5 : 9,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF4A4A4A),
            height: 1.1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          snapshot.targetWeightKg == null
              ? l10n.analysisTargetWeightUnset
              : l10n.analysisTargetWeightLabel(
                  formatAnalysisWeight(snapshot.targetWeightKg!),
                ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 8,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF6B6B6B),
            height: 1.0,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: hasPoints
              ? WeightTrendChart(
                  points: snapshot.weightPoints,
                  rangeStart: snapshot.rangeStart,
                  rangeEnd: snapshot.rangeEnd,
                  targetWeightKg: snapshot.targetWeightKg,
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
        if (hasPoints) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              _legendDot(kAnalysisWeightLineColor),
              const SizedBox(width: 4),
              Text(
                l10n.analysisWeightLegendWeight,
                style: const TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF5A5A5A),
                ),
              ),
              const SizedBox(width: 10),
              _legendDot(kAnalysisTargetLineColor),
              const SizedBox(width: 4),
              Text(
                l10n.analysisWeightLegendTarget,
                style: const TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF5A5A5A),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  String _weightSummaryLine() {
    if (snapshot.startWeightKg == null ||
        snapshot.currentWeightKg == null ||
        snapshot.weightChangeKg == null) {
      return l10n.analysisNoRecord;
    }
    final start = formatAnalysisWeight(snapshot.startWeightKg!);
    final current = formatAnalysisWeight(snapshot.currentWeightKg!);
    final change = formatAnalysisWeightChange(snapshot.weightChangeKg!);
    return '${l10n.analysisWeightStart} ${start}kg   '
        '${l10n.analysisWeightCurrent} ${current}kg   '
        '${l10n.analysisWeightChange} ${change}kg';
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
        const SizedBox(height: 6),
        if (!hasFeedback)
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
          )
        else ...[
          SizedBox(
            height: 118,
            child: Row(
              children: [
                SizedBox(
                  width: 112,
                  height: 112,
                  child: FeedbackPieChart(items: snapshot.pieItems),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < snapshot.pieItems.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: _legendRow(
                            color: colors[i],
                            item: snapshot.pieItems[i],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (snapshot.topFeedbackItems.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              l10n.analysisFeedbackTotalTopThree(snapshot.totalFeedbackCount),
              maxLines: 1,
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
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${i + 1}. ${_feedbackLabel(snapshot.topFeedbackItems[i].key)} '
                  '(${l10n.analysisFeedbackCountAndPercent(snapshot.topFeedbackItems[i].count, snapshot.topFeedbackItems[i].percentage)})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isEnglish ? 8.5 : 9,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF4A4A4A),
                    height: 1.15,
                  ),
                ),
              ),
          ],
        ],
      ],
    );
  }

  Widget _legendRow({
    required Color color,
    required AnalysisFeedbackItem item,
  }) {
    return Row(
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
        Expanded(
          child: Text(
            _feedbackLabel(item.key),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isEnglish ? 8 : 8.5,
              fontWeight: FontWeight.w600,
              color: const Color(0xFF3A3A3A),
              height: 1.0,
            ),
          ),
        ),
        Text(
          l10n.analysisFeedbackLegendValue(item.count, item.percentage),
          style: TextStyle(
            fontSize: isEnglish ? 8 : 8.5,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF5A5A5A),
            height: 1.0,
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

  Widget _legendDot(Color color) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
