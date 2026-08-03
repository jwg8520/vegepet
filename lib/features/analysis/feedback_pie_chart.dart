import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vegepet/features/analysis/analysis_models.dart';

const Color kAnalysisPiePerfect = Color(0xFFA8B8AE);
const Color kAnalysisPieTop1 = Color(0xFFB8AFC5);
const Color kAnalysisPieTop2 = Color(0xFFC9B8AE);
const Color kAnalysisPieTop3 = Color(0xFFAEBBC7);
const Color kAnalysisPieOther = Color(0xFFC2C2BC);

Color analysisPieColorForKey(String key, int indexAmongNutrients) {
  if (key == kAnalysisFeedbackPerfectKey) return kAnalysisPiePerfect;
  if (key == kAnalysisFeedbackOtherKey) return kAnalysisPieOther;
  switch (indexAmongNutrients) {
    case 0:
      return kAnalysisPieTop1;
    case 1:
      return kAnalysisPieTop2;
    default:
      return kAnalysisPieTop3;
  }
}

List<Color> analysisPieColorsForItems(List<AnalysisFeedbackItem> items) {
  var nutrientIndex = 0;
  return items.map((item) {
    if (item.key == kAnalysisFeedbackPerfectKey) {
      return kAnalysisPiePerfect;
    }
    if (item.key == kAnalysisFeedbackOtherKey) {
      return kAnalysisPieOther;
    }
    final color = analysisPieColorForKey(item.key, nutrientIndex);
    nutrientIndex += 1;
    return color;
  }).toList();
}

class FeedbackPieChart extends StatelessWidget {
  const FeedbackPieChart({super.key, required this.items});

  final List<AnalysisFeedbackItem> items;

  @override
  Widget build(BuildContext context) {
    final colors = analysisPieColorsForItems(items);
    return CustomPaint(
      painter: _FeedbackPiePainter(items: items, colors: colors),
      child: const SizedBox.expand(),
    );
  }
}

class _FeedbackPiePainter extends CustomPainter {
  _FeedbackPiePainter({required this.items, required this.colors});

  final List<AnalysisFeedbackItem> items;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty) return;
    final total = items.fold<int>(0, (s, e) => s + e.count);
    if (total <= 0) return;

    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    final radius = side / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    const gapRad = 0.035;
    var start = -math.pi / 2;

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final sweep = (item.count / total) * math.pi * 2;
      final drawSweep = math.max(0.0, sweep - gapRad);
      final paint = Paint()
        ..color = colors[i]
        ..style = PaintingStyle.fill;
      canvas.drawArc(rect, start, drawSweep, true, paint);

      final mid = start + drawSweep / 2;
      final deg = drawSweep * 180 / math.pi;
      if (deg >= 20 || item.percentage >= 6) {
        final labelPos = Offset(
          center.dx + math.cos(mid) * radius * 0.58,
          center.dy + math.sin(mid) * radius * 0.58,
        );
        final tp = TextPainter(
          text: TextSpan(
            text: '${item.percentage}%',
            style: const TextStyle(
              color: Color(0xFF3D3D3D),
              fontSize: 9,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        tp.paint(
          canvas,
          Offset(labelPos.dx - tp.width / 2, labelPos.dy - tp.height / 2),
        );
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _FeedbackPiePainter oldDelegate) {
    return oldDelegate.items != items || oldDelegate.colors != colors;
  }
}
