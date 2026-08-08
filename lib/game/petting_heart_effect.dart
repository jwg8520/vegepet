import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:avopet/game/petting_heart_tune.dart';

/// 중앙 기준 하트 Path (size = 전체 높이 기준).
Path buildHeartPath(double size) {
  final path = Path();
  final w = size * 0.52;
  final h = size;
  path.moveTo(0, h * 0.28);
  path.cubicTo(-w, -h * 0.08, -w, h * 0.52, 0, h * 0.92);
  path.cubicTo(w, h * 0.52, w, -h * 0.08, 0, h * 0.28);
  path.close();
  return path;
}

double _easeOutCubic(double t) {
  final p = t - 1.0;
  return p * p * p + 1.0;
}

/// 쓰다듬기 성공 시 펫 머리 위에서 떠오르며 사라지는 하트 이펙트 (시각 전용).
class PettingHeartEffectComponent extends PositionComponent {
  PettingHeartEffectComponent({
    required PettingHeartTuneConfig tune,
    required Vector2 startPosition,
  }) : _tune = tune.clone(),
       _startX = startPosition.x,
       _startY = startPosition.y,
       super(
         position: startPosition.clone(),
         anchor: Anchor.center,
         // 펫 Y-sort(100~600) 위에 항상 표시.
         priority: 700,
       );

  final PettingHeartTuneConfig _tune;
  final double _startX;
  final double _startY;

  double _elapsed = 0;
  double _currentOpacity = 1;
  double _currentScale = 1;

  late final Path _heartPath;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    _heartPath = buildHeartPath(_tune.size);
    _currentScale = _tune.scaleStart;
    _currentOpacity = _tune.opacity;
  }

  @override
  void render(Canvas canvas) {
    final paint = Paint()
      ..color = _tune.color.withValues(alpha: _currentOpacity)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.save();
    canvas.scale(_currentScale, _currentScale);
    canvas.drawPath(_heartPath, paint);
    canvas.restore();
  }

  @override
  void update(double dt) {
    super.update(dt);
    _elapsed += dt;
    final duration = _tune.durationSeconds;
    final rawT = duration <= 0 ? 1.0 : (_elapsed / duration).clamp(0.0, 1.0);
    if (rawT >= 1.0) {
      removeFromParent();
      return;
    }

    final eased = _easeOutCubic(rawT);
    position.setValues(_startX, _startY - _tune.riseDistance * eased);
    _currentScale =
        _tune.scaleStart + (_tune.scaleEnd - _tune.scaleStart) * eased;
    _currentOpacity = _tune.opacity * (1.0 - eased);
  }
}
