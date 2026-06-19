import 'dart:async';
import 'dart:math';

import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import 'package:vegepet/game/cat_sco_baby_assets.dart';
import 'package:vegepet/game/pet_motion.dart';
import 'package:vegepet/game/yard_game.dart';

/// cat_sco baby Flame 표시 크기 (튜닝 가능).
const double kVegePetDisplaySize = 56;

/// cat_sco baby 오두막 문 앞 초기 스폰 위치 (844×390, 추후 튜닝).
final Vector2 kCatScoBabySpawnPosition = Vector2(415, 225);

/// walk / run 이동 속도 (논리 px/sec).
const double kVegePetWalkSpeed = 38;
const double kVegePetRunSpeed = 72;

/// 8방향 이동 단위 벡터.
final List<Vector2> kVegePetEightDirections = [
  Vector2(0, -1),
  Vector2(0, 1),
  Vector2(-1, 0),
  Vector2(1, 0),
  Vector2(-0.7071, -0.7071),
  Vector2(0.7071, -0.7071),
  Vector2(-0.7071, 0.7071),
  Vector2(0.7071, 0.7071),
];

/// Flame 마당 위 cat_sco baby 베지펫 컴포넌트.
///
/// 향후 species internal code / stage 별 확장 가능. 현재: cat_sco + baby.
class VegePetComponent extends PositionComponent
    with HasGameReference<YardGame> {
  VegePetComponent({
    required this.userPetId,
    this.isDebugOnly = false,
    Vector2? initialPosition,
  }) : super(
         position: initialPosition ?? kCatScoBabySpawnPosition.clone(),
         anchor: Anchor.bottomCenter,
         size: Vector2.all(kVegePetDisplaySize),
         priority: 8,
       );

  final String userPetId;
  final bool isDebugOnly;

  CatScoBabyAssets? _assets;
  SpriteAnimationComponent? _animChild;

  PetMotion _motion = PetMotion.idle;
  bool _lyingDown = false;
  final bool _autoBehavior = true;
  bool _manualControl = false;
  bool _isMoving = false;
  bool _facingLeft = false;
  double _speedMultiplier = 1.0;
  int _repeatRemaining = 1;

  Vector2 _moveDirection = Vector2.zero();
  double _moveSpeed = kVegePetWalkSpeed;
  double _moveTimeLeft = 0;

  Timer? _autoTimer;
  Timer? _motionTimer;
  final Random _random = Random();

  bool get isLyingDown => _lyingDown;
  PetMotion get currentMotion => _motion;

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    debugPrint(
      'VegePetComponent onLoad: userPetId=$userPetId, debugOnly=$isDebugOnly, flamePrefix=$kCatScoBabyFlamePrefix',
    );
    await CatScoBabyAssets.preflightAssets(game);
    _assets = await CatScoBabyAssets.load(game);
    debugPrint('VegePetComponent onLoad: assets ready for userPetId=$userPetId');
    await _enterIdle(resetAuto: false);
    _scheduleAutoBehavior(delay: _randomIdleDelay());
  }

  @override
  void onRemove() {
    _autoTimer?.stop();
    _motionTimer?.stop();
    super.onRemove();
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (_assets == null) return;

    final scaledDt = dt * _speedMultiplier;

    _autoTimer?.update(scaledDt);
    _motionTimer?.update(scaledDt);

    if (_isMoving && _moveTimeLeft > 0) {
      _moveTimeLeft -= scaledDt;
      final velocity = _moveDirection * _moveSpeed;
      final next = position + velocity * scaledDt;
      if (game.canPetMoveTo(position, next)) {
        position.setFrom(next);
        _updateFacingFromDirection(_moveDirection);
      } else {
        _stopMovement();
        if (!_lyingDown) {
          unawaited(_enterIdle(resetAuto: !_manualControl));
        }
      }
      if (_moveTimeLeft <= 0) {
        _stopMovement();
        if (_motion == PetMotion.walk || _motion == PetMotion.run) {
          if (_repeatRemaining > 1) {
            _repeatRemaining--;
            unawaited(_startDirectionalMove(_motion));
          } else if (!_lyingDown) {
            unawaited(_enterIdle(resetAuto: !_manualControl));
          }
        }
      }
    }
  }

  Future<void> playMotion(
    PetMotion motion, {
    double speedMultiplier = 1.0,
    int repeatCount = 1,
    bool fromAuto = false,
  }) async {
    if (_assets == null) return;
    if (!fromAuto) _manualControl = true;

    _speedMultiplier = speedMultiplier.clamp(0.25, 3.0);
    _repeatRemaining = repeatCount.clamp(1, 10);
    _autoTimer?.stop();

    switch (motion) {
      case PetMotion.idle:
        if (_lyingDown) {
          debugPrint('[VegePet] idle blocked while lying down');
          return;
        }
        await _enterIdle(resetAuto: !fromAuto);
      case PetMotion.walk:
        if (_lyingDown) {
          debugPrint('[VegePet] walk blocked while lying down');
          return;
        }
        await _startDirectionalMove(PetMotion.walk);
      case PetMotion.run:
        if (_lyingDown) {
          debugPrint('[VegePet] run blocked while lying down');
          return;
        }
        await _startDirectionalMove(PetMotion.run);
      case PetMotion.lieDown:
        await _playLieDown();
      case PetMotion.lyingIdle:
        await _enterLyingIdle();
      case PetMotion.standUp:
        await _playStandUp();
      case PetMotion.kneading:
        await _playInteractionMotion(PetMotion.kneading);
      case PetMotion.play:
        await _playInteractionMotion(PetMotion.play);
    }

    if (!fromAuto) {
      _manualControl = false;
      _scheduleAutoBehavior(delay: _randomIdleDelay());
    }
  }

  void _scheduleAutoBehavior({required double delay}) {
    if (!_autoBehavior || _manualControl || _assets == null) return;
    _autoTimer?.stop();
    _autoTimer = Timer(
      delay,
      onTick: () {
        if (!isMounted || _manualControl) return;
        unawaited(_runAutoBehavior());
      },
    );
    _autoTimer!.start();
  }

  Future<void> _runAutoBehavior() async {
    if (_manualControl || _assets == null) return;

    if (_lyingDown) {
      if (_random.nextDouble() < 0.35) {
        await playMotion(PetMotion.standUp, fromAuto: true);
      } else {
        _scheduleAutoBehavior(delay: 3 + _random.nextDouble() * 5);
      }
      return;
    }

    final roll = _random.nextDouble();
    if (roll < 0.30) {
      await playMotion(PetMotion.idle, fromAuto: true);
      _scheduleAutoBehavior(delay: 2 + _random.nextDouble() * 3);
    } else if (roll < 0.55) {
      await playMotion(
        PetMotion.walk,
        fromAuto: true,
        repeatCount: 1 + _random.nextInt(2),
      );
    } else if (roll < 0.75) {
      await playMotion(PetMotion.run, fromAuto: true, repeatCount: 1);
    } else {
      await playMotion(PetMotion.lieDown, fromAuto: true);
    }
  }

  Future<void> _enterIdle({bool resetAuto = true}) async {
    _motion = PetMotion.idle;
    _lyingDown = false;
    _stopMovement();
    final anim = _cloneAnimation(_assets!.idleAnimation, loop: true);
    await _showAnimation(anim);
    if (resetAuto) {
      _scheduleAutoBehavior(delay: _randomIdleDelay());
    }
  }

  Future<void> _startDirectionalMove(PetMotion motion) async {
    _motion = motion;
    _lyingDown = false;
    _moveSpeed = motion == PetMotion.run
        ? kVegePetRunSpeed
        : kVegePetWalkSpeed;

    _moveDirection =
        kVegePetEightDirections[_random.nextInt(kVegePetEightDirections.length)];
    _isMoving = true;
    _moveTimeLeft = 1.0 + _random.nextDouble() * 2.0;

    final anim = motion == PetMotion.run
        ? _cloneAnimation(_assets!.runAnimation, loop: true)
        : _cloneAnimation(_assets!.walkAnimation, loop: true);
    await _showAnimation(anim);
  }

  Future<void> _playLieDown() async {
    _motion = PetMotion.lieDown;
    _stopMovement();
    final anim = _cloneAnimation(_assets!.lieDownAnimation, loop: false);
    await _showAnimation(anim);
    await _waitForAnimation(anim);
    await _enterLyingIdle();
  }

  Future<void> _enterLyingIdle() async {
    _motion = PetMotion.lyingIdle;
    _lyingDown = true;
    _stopMovement();
    final anim = _cloneAnimation(_assets!.lyingIdleAnimation, loop: true);
    await _showAnimation(anim);
    _scheduleAutoBehavior(delay: 3 + _random.nextDouble() * 5);
  }

  Future<void> _playStandUp() async {
    if (!_lyingDown) {
      await _enterIdle();
      return;
    }
    _motion = PetMotion.standUp;
    final anim = _cloneAnimation(_assets!.standUpAnimation, loop: false);
    await _showAnimation(anim);
    await _waitForAnimation(anim);
    _lyingDown = false;
    await _enterIdle();
  }

  Future<void> _playInteractionMotion(PetMotion motion) async {
    if (_lyingDown) {
      await _playStandUp();
      if (!isMounted) return;
    }
    _motion = motion;
    _stopMovement();

    final source = switch (motion) {
      PetMotion.kneading => _assets!.kneadingAnimation,
      PetMotion.play => _assets!.playAnimation,
      _ => null,
    };
    if (source == null) return;

    var remaining = _repeatRemaining;
    while (remaining > 0 && isMounted) {
      final anim = _cloneAnimation(source, loop: false);
      await _showAnimation(anim);
      await _waitForAnimation(anim);
      remaining--;
    }
    await _enterIdle();
  }

  Future<void> _showAnimation(SpriteAnimation animation) async {
    _animChild?.removeFromParent();

    for (final frame in animation.frames) {
      frame.stepTime = _assets!.baseStepTime / _speedMultiplier;
    }

    _animChild = SpriteAnimationComponent(
      animation: animation,
      size: Vector2.all(kVegePetDisplaySize),
      anchor: Anchor.center,
      position: size / 2,
    );
    add(_animChild!);
    _applyFacingFlip();
  }

  Future<void> _waitForAnimation(SpriteAnimation animation) async {
    final total = animation.frames.fold<double>(
      0,
      (sum, f) => sum + f.stepTime,
    );
    final completer = Completer<void>();
    _motionTimer?.stop();
    _motionTimer = Timer(
      total,
      onTick: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
    _motionTimer!.start();
    return completer.future;
  }

  SpriteAnimation _cloneAnimation(
    SpriteAnimation source, {
    required bool loop,
  }) {
    return SpriteAnimation.spriteList(
      source.frames.map((f) => f.sprite).toList(),
      stepTime: source.frames.isEmpty ? 0.14 : source.frames.first.stepTime,
      loop: loop,
    );
  }

  void _stopMovement() {
    _isMoving = false;
    _moveTimeLeft = 0;
    _moveDirection = Vector2.zero();
  }

  void _updateFacingFromDirection(Vector2 dir) {
    if (dir.x < -0.01) {
      _facingLeft = true;
    } else if (dir.x > 0.01) {
      _facingLeft = false;
    }
    _applyFacingFlip();
  }

  void _applyFacingFlip() {
    final child = _animChild;
    if (child == null) return;
    child.scale = Vector2(_facingLeft ? -1.0 : 1.0, 1.0);
  }

  double _randomIdleDelay() => 2 + _random.nextDouble() * 3;
}
