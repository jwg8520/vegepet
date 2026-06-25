import 'dart:async';
import 'dart:math';
import 'dart:ui' show BlurStyle, Canvas, MaskFilter, Offset, Paint, Rect;

import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import 'package:vegepet/game/cat_sco_baby_assets.dart';
import 'package:vegepet/game/pet_motion.dart';
import 'package:vegepet/game/pet_motion_tune.dart';
import 'package:vegepet/game/pet_shadow_tune.dart';
import 'package:vegepet/game/yard_game.dart';

/// cat_sco baby Flame 표시 크기 (튜닝 가능).
const double kVegePetDisplaySize = 56;

/// cat_sco baby 발밑 충돌 footprint 크기/보정값 (이동 차단 전용, 추후 튜닝).
///
/// 펫 전체 sprite 가 아니라 발밑 근처의 작은 사각형을 충돌 기준으로 삼아,
/// 오두막에 몸이 시각적으로 살짝 걸쳐 보이는 문제를 줄인다. 너무 크게 잡으면
/// 이동이 과하게 막히므로 발밑 영역 정도로만 둔다.
const double kCatScoBabyCollisionFootprintW = 34;
const double kCatScoBabyCollisionFootprintH = 18;

/// 실제 발밑(position.y, bottomCenter)보다 살짝 위로 올린 보정값(음수 = 위).
const double kCatScoBabyCollisionFootprintYOffset = -6;

/// cat_sco baby 오두막 문 앞 초기 스폰 위치 (844×390, 추후 튜닝).
final Vector2 kCatScoBabySpawnPosition = Vector2(380, 250);

/// walk / run 이동 속도 (논리 px/sec).
const double kVegePetWalkSpeed = 38;
const double kVegePetRunSpeed = 72;

/// 베지펫 이동 가능 여부 판정 콜백 (단일 점 기준, 기존 호환용).
///
/// [current] 에서 [next] 로 이동해도 되는지(collision mask)를
/// 반환한다. YardGame 을 직접 import/cast 하지 않고 콜백으로 주입해 결합을 낮춘다.
typedef PetMoveValidator = bool Function(Vector2 current, Vector2 next);

/// 베지펫 footprint(발밑 영역) 기준 이동 가능 여부 판정 콜백.
///
/// 발밑 한 점이 아니라 footprint sample point 목록 전체를 검사한다.
typedef PetFootprintMoveValidator =
    bool Function(List<Vector2> currentPoints, List<Vector2> nextPoints);

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
    required this.canMoveFootprintTo,
    this.isDebugOnly = false,
    Vector2? initialPosition,
  }) : super(
         position: initialPosition ?? kCatScoBabySpawnPosition.clone(),
         anchor: Anchor.bottomCenter,
         size: Vector2.all(kVegePetDisplaySize),
         priority: 8,
       );

  final String userPetId;

  /// footprint 기준 이동 가능 여부 판정 콜백(YardGame.canPetFootprintMoveTo 주입).
  /// 자동/수동 모든 실제 position 변경은 반드시 이 콜백을 거쳐야 한다.
  final PetFootprintMoveValidator canMoveFootprintTo;

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

  /// debug 방향키(수동 run)로 이동 중인지 여부. 수동 이동 중에는 자동 행동
  /// 스케줄러가 끼어들지 않고, 충돌 시에도 임의 방향으로 전환하지 않는다.
  bool _manualRunActive = false;

  Timer? _autoTimer;
  Timer? _motionTimer;
  final Random _random = Random();

  bool get isLyingDown => _lyingDown;
  PetMotion get currentMotion => _motion;

  /// 발밑 충돌 footprint 사각형(844×390 논리 좌표). 이동 차단 전용.
  ///
  /// 쓰다듬기 터치 판정용 hitbox 와는 의미가 다르다(그쪽은 YardGame 쪽 API).
  Rect get collisionFootprintRect {
    final cy = position.y + kCatScoBabyCollisionFootprintYOffset;
    return Rect.fromCenter(
      center: Offset(position.x, cy),
      width: kCatScoBabyCollisionFootprintW,
      height: kCatScoBabyCollisionFootprintH,
    );
  }

  /// 현재 위치 기준 footprint sample point 9개.
  List<Vector2> get collisionSamplePoints => collisionSamplePointsAt(position);

  /// [footPos](발밑/bottomCenter 좌표) 기준 footprint sample point 9개.
  ///
  /// center / left / right / top / bottom / 네 모서리 순서.
  List<Vector2> collisionSamplePointsAt(Vector2 footPos) {
    final cx = footPos.x;
    final cy = footPos.y + kCatScoBabyCollisionFootprintYOffset;
    final hw = kCatScoBabyCollisionFootprintW / 2;
    final hh = kCatScoBabyCollisionFootprintH / 2;
    return [
      Vector2(cx, cy),
      Vector2(cx - hw, cy),
      Vector2(cx + hw, cy),
      Vector2(cx, cy - hh),
      Vector2(cx, cy + hh),
      Vector2(cx - hw, cy - hh),
      Vector2(cx + hw, cy - hh),
      Vector2(cx - hw, cy + hh),
      Vector2(cx + hw, cy + hh),
    ];
  }

  @override
  void render(Canvas canvas) {
    final tune = game.petShadowTune;
    if (tune.enabled) {
      _renderPetShadow(canvas, tune);
    }
    super.render(canvas);
  }

  /// 펫 발밑 타원형 그림자 (시각 전용, 충돌/터치 무관).
  void _renderPetShadow(Canvas canvas, PetShadowTuneConfig tune) {
    final shadowWidth = size.x * tune.widthScale;
    final shadowHeight = size.y * tune.heightScale;
    final centerX = size.x / 2 + tune.offsetX;
    final centerY = size.y + tune.offsetY;
    final rect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: shadowWidth,
      height: shadowHeight,
    );
    final paint = Paint()
      ..color = tune.paintColor
      ..maskFilter = tune.blurSigma > 0
          ? MaskFilter.blur(BlurStyle.normal, tune.blurSigma)
          : null;
    canvas.drawOval(rect, paint);
  }

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    debugPrint(
      'VegePetComponent onLoad: userPetId=$userPetId, debugOnly=$isDebugOnly, flamePrefix=$kCatScoBabyFlamePrefix',
    );
    await CatScoBabyAssets.preflightAssets(game);
    _assets = await CatScoBabyAssets.load(game);
    debugPrint(
      'VegePetComponent onLoad: assets ready for userPetId=$userPetId',
    );
    // 분양 직후 첫 idle 표시만 좌측 향함. 이후 이동 방향에 따라 좌우 전환.
    _facingLeft = true;
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
      _moveWithCollision(scaledDt);

      // _handleMoveBlocked 가 idle 로 전환하면 _isMoving 이 false 가 되어
      // 아래 repeat/idle 처리는 건너뛴다(이미 idle 진입).
      if (_isMoving && _moveTimeLeft <= 0) {
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

  /// 충돌 검사를 거쳐 한 프레임 이동을 수행한다.
  ///
  /// 한 프레임 이동량이 크면(빠른 속도/큰 dt) polygon 을 관통할 수 있으므로
  /// 4px 단위 sub-step 으로 쪼개 매 단계 [canMoveTo] 를 검사한다. 막히면 즉시
  /// [_handleMoveBlocked] 로 방향 전환/idle 처리하고 중단한다.
  void _moveWithCollision(double scaledDt) {
    if (_moveDirection.isZero()) return;

    final delta = _moveDirection * (_moveSpeed * scaledDt);
    final distance = delta.length;
    if (distance <= 0) return;

    final steps = max(1, (distance / 4).ceil());
    final stepDelta = delta / steps.toDouble();

    for (var i = 0; i < steps; i++) {
      final current = position.clone();
      final next = current + stepDelta;
      if (canMoveFootprintTo(
        collisionSamplePointsAt(current),
        collisionSamplePointsAt(next),
      )) {
        position.setFrom(next);
        _updateFacingFromDirection(_moveDirection);
      } else {
        if (_manualRunActive) {
          // 수동 방향키 이동: 막히면 그 방향으로만 멈춘다(임의 방향 전환/ idle
          // 전환 안 함). 사용자가 반대 방향키를 누르면 빠져나올 수 있다.
          break;
        }
        _handleMoveBlocked(current);
        break;
      }
    }
  }

  /// 오두막/마당 경계에 막혔을 때: 같은 방향으로 계속 밀지 않고 이동 가능한
  /// 대안 방향으로 전환한다. 어떤 방향도 불가하면 idle 로 전환한다.
  void _handleMoveBlocked(Vector2 current) {
    if (_lyingDown) {
      _stopMovement();
      return;
    }

    final newDirection = _pickAlternativeDirection(current);
    if (newDirection != null) {
      _moveDirection = newDirection;
      _updateFacingFromDirection(_moveDirection);
      return;
    }

    _stopMovement();
    unawaited(_enterIdle(resetAuto: !_manualControl));
  }

  /// 현재 위치에서 이동 가능한 대안 8방향을 찾는다. 현재 방향의 반대 방향을
  /// 우선 검사하고, 그 다음 8방향을 랜덤 순서로 검사한다. 모두 막혀 있으면 null.
  Vector2? _pickAlternativeDirection(Vector2 current) {
    const probe = 6.0;

    final candidates = <Vector2>[];
    if (!_moveDirection.isZero()) {
      candidates.add(-_moveDirection);
    }
    candidates.addAll(
      List<Vector2>.from(kVegePetEightDirections)..shuffle(_random),
    );

    for (final dir in candidates) {
      if (dir.isZero()) continue;
      final next = current + dir * probe;
      if (canMoveFootprintTo(
        collisionSamplePointsAt(current),
        collisionSamplePointsAt(next),
      )) {
        return dir.clone();
      }
    }
    return null;
  }

  /// debug 방향키: 현재 [direction] 방향으로 run 모션 수동 이동을 시작한다.
  ///
  /// [direction] 은 normalize 되어 대각선이 과속하지 않는다. lie_down/lying_idle
  /// 상태에서는 무시한다(이번 단계 정책). 수동 이동 중에는 자동 행동을 멈춘다.
  void startManualRun(Vector2 direction, {double speedMultiplier = 1.0}) {
    if (_assets == null) return;
    if (direction.isZero()) return;
    if (_lyingDown) {
      debugPrint('[VegePet] manual run ignored while lying down');
      return;
    }

    _manualControl = true;
    _manualRunActive = true;
    _autoTimer?.stop();

    _speedMultiplier = speedMultiplier.clamp(0.25, 3.0);
    _motion = PetMotion.run;
    _moveSpeed = kVegePetRunSpeed;
    _moveDirection = direction.normalized();
    _isMoving = true;
    // 버튼을 누르고 있는 동안 계속 이동. 멈춤은 stopManualRun 으로 처리.
    _moveTimeLeft = double.infinity;
    _updateFacingFromDirection(_moveDirection);

    unawaited(
      _showAnimation(_cloneAnimation(_assets!.runAnimation, loop: true)),
    );
  }

  /// debug 방향키: 수동 run 이동을 멈추고 idle 로 복귀한다.
  void stopManualRun() {
    if (!_manualRunActive) return;
    _manualRunActive = false;
    _stopMovement();
    _manualControl = false;
    if (!_lyingDown) {
      unawaited(_enterIdle(resetAuto: true));
    }
  }

  Future<void> playMotion(
    PetMotion motion, {
    double? speedMultiplier,
    int? repeatCount,
    bool fromAuto = false,
  }) async {
    if (_assets == null) return;
    if (!fromAuto) {
      _manualControl = true;
      _manualRunActive = false;
    }

    final defaults = kPetMotionDefaultTuningFor(motion);
    _speedMultiplier = (speedMultiplier ?? defaults.speedMultiplier).clamp(
      0.25,
      3.0,
    );
    _repeatRemaining = (repeatCount ?? defaults.repeatCount).clamp(1, 10);
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
    _speedMultiplier = kPetMotionDefaultTuningFor(
      PetMotion.idle,
    ).speedMultiplier.clamp(0.25, 3.0);
    final anim = _cloneAnimation(_assets!.idleAnimation, loop: true);
    await _showAnimation(anim);
    if (resetAuto) {
      _scheduleAutoBehavior(delay: _randomIdleDelay());
    }
  }

  Future<void> _startDirectionalMove(PetMotion motion) async {
    _motion = motion;
    _lyingDown = false;
    _moveSpeed = motion == PetMotion.run ? kVegePetRunSpeed : kVegePetWalkSpeed;

    _moveDirection =
        kVegePetEightDirections[_random.nextInt(
          kVegePetEightDirections.length,
        )];
    _updateFacingFromDirection(_moveDirection);
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
    _speedMultiplier = kPetMotionDefaultTuningFor(
      PetMotion.lyingIdle,
    ).speedMultiplier.clamp(0.25, 3.0);
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
