import 'package:flutter/material.dart';
import 'package:vegepet/features/analysis/analysis_helpers.dart';
import 'package:vegepet/features/analysis/analysis_models.dart';

const Color kAnalysisWeightLineColor = Color(0xFF78AFA3);
const Color kAnalysisTargetLineColor = Color(0xFFB7A7C8);

/// 설정 패널 “회원 탈퇴” 문구와 동일한 색상.
const Color kAnalysisWithdrawAccentColor = Color(0xFFB92020);

/// 식단일지 목표 달성 문구와 동일한 색상.
const Color kAnalysisGoalAchievedColor = Color(0xFF0051FF);

class WeightTrendChart extends StatelessWidget {
  const WeightTrendChart({
    super.key,
    required this.points,
    required this.period,
    required this.rangeStart,
    required this.rangeEnd,
    required this.targetWeightKg,
    required this.weightLegendLabel,
    required this.targetLegendLabel,
  });

  final List<AnalysisWeightPoint> points;
  final AnalysisPeriod period;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final double? targetWeightKg;
  final String weightLegendLabel;
  final String targetLegendLabel;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WeightTrendPainter(
        points: points,
        period: period,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        targetWeightKg: targetWeightKg,
        weightLegendLabel: weightLegendLabel,
        targetLegendLabel: targetLegendLabel,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _WeightTrendPainter extends CustomPainter {
  _WeightTrendPainter({
    required this.points,
    required this.period,
    required this.rangeStart,
    required this.rangeEnd,
    required this.targetWeightKg,
    required this.weightLegendLabel,
    required this.targetLegendLabel,
  });

  final List<AnalysisWeightPoint> points;
  final AnalysisPeriod period;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final double? targetWeightKg;
  final String weightLegendLabel;
  final String targetLegendLabel;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 34.0;
    const rightPad = 8.0;
    const topPad = 18.0;
    const bottomPad = 20.0;
    final chart = Rect.fromLTRB(
      leftPad,
      topPad,
      size.width - rightPad,
      size.height - bottomPad,
    );
    if (chart.width <= 0 || chart.height <= 0) return;

    final axis = analysisWeightAxisRange(
      points: points,
      targetWeightKg: targetWeightKg,
    );
    final minY = axis.minY;
    final maxY = axis.maxY;
    final ySpan = (maxY - minY).abs() < 0.001 ? 1.0 : (maxY - minY);

    final totalDays = rangeEnd
        .difference(rangeStart)
        .inDays
        .clamp(1, 100000)
        .toDouble();

    double xFor(DateTime date) {
      final t = date.difference(rangeStart).inDays / totalDays;
      return chart.left + chart.width * t.clamp(0.0, 1.0);
    }

    double yFor(double weight) {
      final t = (weight - minY) / ySpan;
      return chart.bottom - chart.height * t.clamp(0.0, 1.0);
    }

    _drawLegend(canvas, chart);

    final gridPaint = Paint()
      ..color = const Color(0xFF000000).withValues(alpha: 0.06)
      ..strokeWidth = 1;
    for (var i = 0; i < 3; i++) {
      final y = chart.top + chart.height * (i / 2);
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
    }

    final labelStyle = TextStyle(
      color: const Color(0xFF6B6B6B).withValues(alpha: 0.9),
      fontSize: 9,
      fontWeight: FontWeight.w600,
      height: 1.0,
    );

    final targetY = targetWeightKg == null ? null : yFor(targetWeightKg!);
    final tickValues = <double>[maxY, (minY + maxY) / 2, minY];

    void drawYLabel(double value, double y) {
      final ty = targetY;
      if (ty != null && (y - ty).abs() < 9) {
        return;
      }
      final tp = TextPainter(
        text: TextSpan(text: value.toStringAsFixed(0), style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: leftPad - 4);
      // 기존 대비 x축 방향 3px 왼쪽.
      tp.paint(
        canvas,
        Offset(chart.left - tp.width - 3 - 3, y - tp.height / 2),
      );
    }

    for (final value in tickValues) {
      drawYLabel(value, yFor(value));
    }

    final resolvedTarget = targetWeightKg;
    final resolvedTargetY = targetY;
    if (resolvedTarget != null && resolvedTargetY != null) {
      final y = resolvedTargetY;
      final dashPaint = Paint()
        ..color = kAnalysisTargetLineColor.withValues(alpha: 0.85)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;
      const dash = 4.0;
      const gap = 3.0;
      var x = chart.left;
      while (x < chart.right) {
        final x2 = (x + dash).clamp(chart.left, chart.right);
        canvas.drawLine(Offset(x, y), Offset(x2, y), dashPaint);
        x += dash + gap;
      }

      final targetTp = TextPainter(
        text: TextSpan(
          text: resolvedTarget.toStringAsFixed(1),
          style: const TextStyle(
            color: kAnalysisTargetLineColor,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: leftPad - 2);
      final targetLabelX = (chart.left - targetTp.width - 3 - 3).clamp(
        0.0,
        chart.left - 2,
      );
      final targetLabelY = (y - targetTp.height / 2).clamp(
        0.0,
        size.height - targetTp.height,
      );
      targetTp.paint(canvas, Offset(targetLabelX, targetLabelY));
    }

    if (points.isNotEmpty) {
      final linePaint = Paint()
        ..color = kAnalysisWeightLineColor
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final p = Offset(xFor(points[i].date), yFor(points[i].weightKg));
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      if (points.length > 1) {
        canvas.drawPath(path, linePaint);
      }
      const pointRadius = 2.6;
      final dotPaint = Paint()..color = kAnalysisWeightLineColor;
      for (final point in points) {
        canvas.drawCircle(
          Offset(xFor(point.date), yFor(point.weightKg)),
          pointRadius,
          dotPaint,
        );
      }

      final showAll = period == AnalysisPeriod.sevenDays;
      final labelIndices = <int>[];
      if (showAll) {
        for (var i = 0; i < points.length; i++) {
          labelIndices.add(i);
        }
      } else {
        // 30일·3개월: 시작 체중 점 + 현재(마지막) 체중 점.
        labelIndices.add(0);
        if (points.length > 1) {
          labelIndices.add(points.length - 1);
        }
      }

      final pointLabelStyle = TextStyle(
        color: kAnalysisWeightLineColor.withValues(alpha: 0.95),
        fontSize: 9,
        fontWeight: FontWeight.w700,
        height: 1.0,
      );
      for (final i in labelIndices) {
        final point = points[i];
        final pointX = xFor(point.date);
        final pointY = yFor(point.weightKg);
        final tp = TextPainter(
          text: TextSpan(
            text: point.weightKg.toStringAsFixed(1),
            style: pointLabelStyle,
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        var labelX = pointX - tp.width / 2;
        var labelY = pointY - pointRadius - 3 - tp.height;
        labelX = labelX.clamp(chart.left, chart.right - tp.width);
        labelY = labelY.clamp(0.0, chart.bottom - tp.height);
        tp.paint(canvas, Offset(labelX, labelY));
      }
    }

    final xLabels = <DateTime>[rangeStart];
    final span = rangeEnd.difference(rangeStart).inDays;
    if (span >= 28) {
      xLabels.add(rangeStart.add(Duration(days: (span / 3).round())));
      xLabels.add(rangeStart.add(Duration(days: (span * 2 / 3).round())));
    } else if (span >= 6) {
      xLabels.add(rangeStart.add(Duration(days: (span / 2).round())));
    }
    if (rangeEnd != rangeStart) xLabels.add(rangeEnd);
    // 시작 체중 기록 날짜는 가로축에 반드시 표시.
    if (points.isNotEmpty) {
      final startWeightDate = DateTime(
        points.first.date.year,
        points.first.date.month,
        points.first.date.day,
      );
      final startKey = '${startWeightDate.month}/${startWeightDate.day}';
      final alreadyListed = xLabels.any(
        (d) => '${d.month}/${d.day}' == startKey,
      );
      if (!alreadyListed) {
        xLabels.add(startWeightDate);
        xLabels.sort((a, b) => a.compareTo(b));
      }
    }

    final seen = <String>{};
    for (final d in xLabels) {
      final key = '${d.month}/${d.day}';
      if (!seen.add(key)) continue;
      final tp = TextPainter(
        text: TextSpan(text: key, style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final x = xFor(d) - tp.width / 2;
      // 기존 대비 y축 방향 3px 아래.
      tp.paint(
        canvas,
        Offset(x.clamp(0.0, size.width - tp.width), chart.bottom + 3 + 3),
      );
    }
  }

  void _drawLegend(Canvas canvas, Rect chart) {
    final style = const TextStyle(
      color: Color(0xFF5A5A5A),
      fontSize: 8,
      fontWeight: FontWeight.w600,
      height: 1.0,
    );
    final weightTp = TextPainter(
      text: TextSpan(text: weightLegendLabel, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    TextPainter? targetTp;
    if (targetWeightKg != null) {
      targetTp = TextPainter(
        text: TextSpan(text: targetLegendLabel, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
    }

    const swatch = 7.0;
    const gap = 4.0;
    const itemGap = 10.0;
    var totalW = swatch + gap + weightTp.width;
    if (targetTp != null) {
      totalW += itemGap + swatch + gap + targetTp.width;
    }

    final legendRight = chart.right;
    final legendLeft = legendRight - totalW;
    final legendBottom = chart.top - 3;
    final legendTop = legendBottom - weightTp.height;
    if (legendTop < 0) return;

    var x = legendLeft;
    final cy = legendTop + weightTp.height / 2;
    final swatchPaint = Paint()..color = kAnalysisWeightLineColor;
    canvas.drawCircle(Offset(x + swatch / 2, cy), swatch / 2, swatchPaint);
    x += swatch + gap;
    weightTp.paint(canvas, Offset(x, legendTop));
    x += weightTp.width;

    if (targetTp != null) {
      x += itemGap;
      final targetPaint = Paint()..color = kAnalysisTargetLineColor;
      canvas.drawCircle(Offset(x + swatch / 2, cy), swatch / 2, targetPaint);
      x += swatch + gap;
      targetTp.paint(canvas, Offset(x, legendTop));
    }
  }

  @override
  bool shouldRepaint(covariant _WeightTrendPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.period != period ||
        oldDelegate.rangeStart != rangeStart ||
        oldDelegate.rangeEnd != rangeEnd ||
        oldDelegate.targetWeightKg != targetWeightKg ||
        oldDelegate.weightLegendLabel != weightLegendLabel ||
        oldDelegate.targetLegendLabel != targetLegendLabel;
  }
}
