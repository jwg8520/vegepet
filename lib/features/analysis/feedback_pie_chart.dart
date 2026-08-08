import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:avopet/features/analysis/analysis_models.dart';

const Color kAnalysisPiePerfect = Color(0xFFA8B8AE);
const Color kAnalysisPieTop1 = Color(0xFFB8AFC5);
const Color kAnalysisPieTop2 = Color(0xFFC9B8AE);
const Color kAnalysisPieTop3 = Color(0xFFAEBBC7);
const Color kAnalysisPieOther = Color(0xFFC2C2BC);

/// 피드백 도넛 기본 지름 (조각 안 %+(개수) 표시용 소폭 확대).
const double kAnalysisFeedbackDonutSize = 136;

/// 도넛 링 두께.
const double kAnalysisFeedbackDonutStrokeWidth = 30;

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
  const FeedbackPieChart({
    super.key,
    required this.items,
    required this.centerLabel,
  });

  final List<AnalysisFeedbackItem> items;
  final String centerLabel;

  @override
  Widget build(BuildContext context) {
    final colors = analysisPieColorsForItems(items);
    return CustomPaint(
      painter: _FeedbackPiePainter(
        items: items,
        colors: colors,
        centerLabel: centerLabel,
        strokeWidth: kAnalysisFeedbackDonutStrokeWidth,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _FeedbackPiePainter extends CustomPainter {
  _FeedbackPiePainter({
    required this.items,
    required this.colors,
    required this.centerLabel,
    required this.strokeWidth,
  });

  final List<AnalysisFeedbackItem> items;
  final List<Color> colors;
  final String centerLabel;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty) return;
    final total = items.fold<int>(0, (s, e) => s + e.count);
    if (total <= 0) return;

    final side = math.min(size.width, size.height);
    final center = Offset(size.width / 2, size.height / 2);
    // 가장자리 clipping 여유.
    final outerRadius = side / 2 - 1;
    final ringStroke = math.min(strokeWidth, outerRadius * 0.55);
    final ringRadius = outerRadius - ringStroke / 2;
    final innerRadius = outerRadius - ringStroke;
    final labelRadius = (outerRadius + innerRadius) / 2;
    final rect = Rect.fromCircle(center: center, radius: ringRadius);

    const gapRad = 0.035;
    var start = -math.pi / 2;

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final sweep = (item.count / total) * math.pi * 2;
      final drawSweep = math.max(0.0, sweep - gapRad);
      final paint = Paint()
        ..color = colors[i]
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringStroke
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(rect, start, drawSweep, false, paint);

      final mid = start + drawSweep / 2;
      final deg = drawSweep * 180 / math.pi;
      if (deg >= 20 || item.percentage >= 6) {
        final labelPos = Offset(
          center.dx + math.cos(mid) * labelRadius,
          center.dy + math.sin(mid) * labelRadius,
        );
        const percentStyle = TextStyle(
          color: Color(0xFF3D3D3D),
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1.0,
        );
        const countStyle = TextStyle(
          color: Color(0xFF3D3D3D),
          fontSize: 8,
          fontWeight: FontWeight.w600,
          height: 1.0,
        );
        final percentTp = TextPainter(
          text: TextSpan(text: '${item.percentage}%', style: percentStyle),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final countTp = TextPainter(
          text: TextSpan(text: '(${item.count})', style: countStyle),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        const lineGap = 1.0;
        final blockH = percentTp.height + lineGap + countTp.height;
        final top = labelPos.dy - blockH / 2;
        percentTp.paint(canvas, Offset(labelPos.dx - percentTp.width / 2, top));
        countTp.paint(
          canvas,
          Offset(
            labelPos.dx - countTp.width / 2,
            top + percentTp.height + lineGap,
          ),
        );
      }
      start += sweep;
    }

    _paintCenterTotal(canvas, center, innerRadius * 2, centerLabel);
  }

  void _paintCenterTotal(
    Canvas canvas,
    Offset center,
    double holeDiameter,
    String text,
  ) {
    if (text.isEmpty || holeDiameter <= 0) return;
    final maxWidth = holeDiameter * 0.88;
    var fontSize = 11.0;

    TextPainter build(double size) {
      return TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: const Color(0xFF3A3A3A),
            fontSize: size,
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
    }

    var tp = build(fontSize);
    // 3자리 등에서 구멍 밖으로 나가면 소폭만 축소 (극단 FittedBox 금지).
    while (tp.width > maxWidth && fontSize > 8.5) {
      fontSize -= 0.5;
      tp = build(fontSize);
    }

    final offset = Offset(center.dx - tp.width / 2, center.dy - tp.height / 2);
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _FeedbackPiePainter oldDelegate) {
    if (oldDelegate.centerLabel != centerLabel) return true;
    if (oldDelegate.strokeWidth != strokeWidth) return true;
    if (oldDelegate.items.length != items.length) return true;
    if (oldDelegate.colors.length != colors.length) return true;
    for (var i = 0; i < items.length; i++) {
      final a = items[i];
      final b = oldDelegate.items[i];
      if (a.key != b.key ||
          a.count != b.count ||
          a.percentage != b.percentage) {
        return true;
      }
      if (oldDelegate.colors[i] != colors[i]) return true;
    }
    return false;
  }
}
