import 'package:flutter/material.dart';
import 'package:vegepet/features/analysis/analysis_helpers.dart';
import 'package:vegepet/features/analysis/analysis_models.dart';

const Color kAnalysisWeightLineColor = Color(0xFF78AFA3);
const Color kAnalysisTargetLineColor = Color(0xFFB7A7C8);

class WeightTrendChart extends StatelessWidget {
  const WeightTrendChart({
    super.key,
    required this.points,
    required this.rangeStart,
    required this.rangeEnd,
    required this.targetWeightKg,
  });

  final List<AnalysisWeightPoint> points;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final double? targetWeightKg;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WeightTrendPainter(
        points: points,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        targetWeightKg: targetWeightKg,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _WeightTrendPainter extends CustomPainter {
  _WeightTrendPainter({
    required this.points,
    required this.rangeStart,
    required this.rangeEnd,
    required this.targetWeightKg,
  });

  final List<AnalysisWeightPoint> points;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final double? targetWeightKg;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 28.0;
    const rightPad = 6.0;
    const topPad = 8.0;
    const bottomPad = 18.0;
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

    final gridPaint = Paint()
      ..color = const Color(0xFF000000).withValues(alpha: 0.06)
      ..strokeWidth = 1;
    for (var i = 0; i < 3; i++) {
      final y = chart.top + chart.height * (i / 2);
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
    }

    final labelStyle = TextStyle(
      color: const Color(0xFF6B6B6B).withValues(alpha: 0.9),
      fontSize: 8,
      fontWeight: FontWeight.w600,
      height: 1.0,
    );

    void drawYLabel(double value, double y) {
      final tp = TextPainter(
        text: TextSpan(text: value.toStringAsFixed(0), style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: leftPad - 2);
      tp.paint(canvas, Offset(chart.left - tp.width - 3, y - tp.height / 2));
    }

    drawYLabel(maxY, chart.top);
    drawYLabel((minY + maxY) / 2, chart.center.dy);
    drawYLabel(minY, chart.bottom);

    if (targetWeightKg != null) {
      final y = yFor(targetWeightKg!);
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
    }

    if (points.isNotEmpty) {
      final linePaint = Paint()
        ..color = kAnalysisWeightLineColor
        ..strokeWidth = 2.2
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
      final dotPaint = Paint()..color = kAnalysisWeightLineColor;
      for (final point in points) {
        canvas.drawCircle(
          Offset(xFor(point.date), yFor(point.weightKg)),
          2.6,
          dotPaint,
        );
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
      tp.paint(
        canvas,
        Offset(x.clamp(0.0, size.width - tp.width), chart.bottom + 3),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WeightTrendPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.rangeStart != rangeStart ||
        oldDelegate.rangeEnd != rangeEnd ||
        oldDelegate.targetWeightKg != targetWeightKg;
  }
}
