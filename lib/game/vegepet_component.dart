import 'dart:async';
import 'dart:math';
import 'dart:ui' show BlurStyle, Canvas, MaskFilter, Offset, Paint, Rect;

import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import 'package:vegepet/game/pet_motion.dart';
import 'package:vegepet/game/pet_motion_tune.dart';
import 'package:vegepet/game/pet_shadow_tune.dart';
import 'package:vegepet/game/pet_sprite_assets.dart';
import 'package:vegepet/game/yard_game.dart';

/// 기본 스폰 위치 (844×390, 오두막 문 앞).
final Vector2 kDefaultPetSpawnPosition = Vector2(380, 250);

/// 하위 호환 alias.
final Vector2 kCatScoBabySpawnPosition = kDefaultPetSpawnPosition;
const double kVegePetDisplaySize = 72;

/// 발밑 충돌 footprint (이동 차단 전용). sprite 전체 박스가 아니다.
const double kPetCollisionFootprintW = 34;
const double kPetCollisionFootprintH = 18;
const double kPetCollisionFootprintYOffset = -6;

/// 하위 호환 alias.
const double kCatScoBabyCollisionFootprintW = kPetCollisionFootprintW;
const double kCatScoBabyCollisionFootprintH = kPetCollisionFootprintH;
const double kCatScoBabyCollisionFootprintYOffset = kPetCollisionFootprintYOffset;

/// walk / run 이동 속도 (논리 px/sec).
const double kVegePetWalkSpeed = 38;
const double kVegePetRunSpeed = 72;

typedef PetMoveValidator = bool Function(Vector2 current, Vector2 next);

typedef PetFootprintMoveValidator =
    bool Function(List<Vector2> currentPoints, List<Vector2> nextPoints);

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

/// Flame 마당 펫 컴포넌트 (종·단계별 스프라이트, 독립 상태 머신).
class VegePetComponent extends PositionComponent
    with HasGameReference<YardGame> {
  VegePetComponent({
    required this.userPetId,
    required this.speciesCode,
    required this.stage,
    required this.canMoveFootprintTo,
    this.isDebugOnly = false,
    this.isResident = false,
    Vector2? initialPosition,
  }) : displaySize = petDisplaySizeForStage(stage),
       stageFolder = petStageAssetFolder(stage),
       super(
         position: initialPosition ?? kDefaultPetSpawnPosition.clone(),
         anchor: Anchor.bottomCenter,
         size: Vector2.all(petDisplaySizeForStage(stage)),
         priority: 8,
       );

  final String userPetId;
  final String speciesCode;
  final String stage;
  final String stageFolder;
  final double displaySize;
  final PetFootprintMoveValidator canMoveFootprintTo;
  final bool isDebugOnly;
  final bool isResident;

  PetSpriteAssets? _assets;
  SpriteAnimationComponent? _animChild;

  PetMotion _motion = PetMotion.idle;
  bool _isSitting = false;
  int _sittingIdleCycleCount = 0;
  final bool _autoBehavior = true;
  bool _manualControl = false;
  bool _isMoving = false;
  bool _facingLeft = false;
  double _speedMultiplier = 1.0;
  int _repeatRemaining = 1;
  int _motionGeneration = 0;
  bool _eventMotionActive = false;

  Vector2 _moveDirection = Vector2.zero();
  double _moveSpeed = kVegePetWalkSpeed;
  double _moveTimeLeft = 0;

  bool _manualRunActive = false;

  /// walk/run 종료 시 현재 스프라이트 사이클 완료를 기다리는 중인지.
  bool _pendingMoveCycleFinish = false;

  Timer? _autoTimer;
  Timer? _motionTimer;
  final Random _random = Random();

  bool get isSitting => _isSitting;
  bool get isLyingDown => _isSitting; // 하위 호환 (구 lying 상태)
  PetMotion get currentMotion => _motion;
  bool get isDog => speciesCode == 'dog_bic' || speciesCode == 'dog_pom';
  bool get isCat => speciesCode == 'cat_rag' || speciesCode == 'cat_sco';

  Rect get collisionFootprintRect {
    final cy = position.y + kPetCollisionFootprintYOffset;
    return Rect.fromCenter(
      center: Offset(position.x, cy),
      width: kPetCollisionFootprintW,
      height: kPetCollisionFootprintH,
    );
  }

  List<Vector2> get collisionSamplePoints => collisionSamplePointsAt(position);

  List<Vector2> collisionSamplePointsAt(Vector2 footPos) {
    final cx = footPos.x;
    final cy = footPos.y + kPetCollisionFootprintYOffset;
    final hw = kPetCollisionFootprintW / 2;
    final hh = kPetCollisionFootprintH / 2;
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
      'VegePetComponent onLoad: id=$userPetId species=$speciesCode '
      'stage=$stage folder=$stageFolder size=$displaySize',
    );
    await PetSpriteAssets.preflightAssets(
      game,
      speciesCode: speciesCode,
      stageFolder: stageFolder,
    );
    _assets = await PetSpriteAssets.load(
      game,
      speciesCode: speciesCode,
      stageFolder: stageFolder,
    );
    size = Vector2.all(displaySize);
    _facingLeft = true;
    await _enterIdle(resetAuto: false);
    _scheduleAutoBehavior(delay: _randomIdleDelay());
  }

  @override
  void onRemove() {
    _autoTimer?.stop();
    _motionTimer?.stop();
    _motionGeneration++;
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

      if (_isMoving && _moveTimeLeft <= 0) {
        if (_motion == PetMotion.walk || _motion == PetMotion.run) {
          unawaited(_finishDirectionalMoveAfterCycle());
        } else {
          _stopMovement();
        }
      }
    }
  }

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
        if (_manualRunActive) break;
        _handleMoveBlocked(current);
        break;
      }
    }
  }

  void _handleMoveBlocked(Vector2 current) {
    if (_isSitting) {
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
    unawaited(_finishDirectionalMoveAfterCycle());
  }

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

  void startManualRun(Vector2 direction, {double speedMultiplier = 1.0}) {
    if (_assets == null) return;
    if (direction.isZero()) return;
    if (_isSitting || _eventMotionActive) {
      debugPrint('[VegePet] manual run ignored (sitting/event)');
      return;
    }

    _manualControl = true;
    _manualRunActive = true;
    _autoTimer?.stop();
    _motionGeneration++;

    _speedMultiplier = speedMultiplier.clamp(0.25, 3.0);
    _motion = PetMotion.run;
    _moveSpeed = kVegePetRunSpeed;
    _moveDirection = direction.normalized();
    _isMoving = true;
    _moveTimeLeft = double.infinity;
    _updateFacingFromDirection(_moveDirection);

    unawaited(
      _showAnimation(_cloneAnimation(_assets!.runAnimation, loop: true)),
    );
  }

  void stopManualRun() {
    if (!_manualRunActive) return;
    _manualRunActive = false;
    _manualControl = false;
    if (!_isSitting) {
      unawaited(_finishDirectionalMoveAfterCycle());
    } else {
      _stopMovement();
    }
  }

  Future<void> playMotion(
    PetMotion motion, {
    double? speedMultiplier,
    int? repeatCount,
    bool fromAuto = false,
  }) async {
    if (_assets == null) return;

    final isEvent = motion == PetMotion.happy || motion == PetMotion.play;
    if (!fromAuto) {
      _manualControl = true;
      _manualRunActive = false;
    }

    // sitting 중 일반 랜덤/수동 이동·idle·sit 금지 (이벤트·stand 제외)
    if (_isSitting &&
        !isEvent &&
        motion != PetMotion.stand &&
        motion != PetMotion.sittingIdle &&
        motion != PetMotion.sit) {
      if (fromAuto) {
        debugPrint('[VegePet] $motion blocked while sitting');
        _scheduleAutoBehavior(delay: _randomIdleDelay());
        return;
      }
      if (motion == PetMotion.idle ||
          motion == PetMotion.walk ||
          motion == PetMotion.run) {
        debugPrint('[VegePet] $motion blocked while sitting');
        return;
      }
    }

    // sit 직후 sittingIdle 최소 1회 전 stand 금지 (디버그 stand 는 강제 허용)
    if (motion == PetMotion.stand &&
        _isSitting &&
        _sittingIdleCycleCount < 1 &&
        fromAuto) {
      debugPrint('[VegePet] stand blocked until sittingIdle >= 1');
      await _enterSittingIdle(resetAuto: true);
      return;
    }

    final defaults = kPetMotionDefaultTuningFor(motion);
    _speedMultiplier = (speedMultiplier ?? defaults.speedMultiplier).clamp(
      0.25,
      3.0,
    );
    _repeatRemaining = (repeatCount ?? defaults.repeatCount).clamp(1, 10);
    _autoTimer?.stop();

    final gen = ++_motionGeneration;

    switch (motion) {
      case PetMotion.idle:
        await _enterIdle(resetAuto: !fromAuto, generation: gen);
      case PetMotion.walk:
        await _startDirectionalMove(PetMotion.walk, generation: gen);
      case PetMotion.run:
        await _startDirectionalMove(PetMotion.run, generation: gen);
      case PetMotion.sit:
        await _playSit(generation: gen);
      case PetMotion.sittingIdle:
        // fromAuto 여부와 관계없이 다음 자동 행동(stand 포함)을 다시 스케줄한다.
        // resetAuto: !fromAuto 이면 sittingIdle 재진입 후 스케줄이 끊겨 영구 착석한다.
        await _enterSittingIdle(resetAuto: true, generation: gen);
      case PetMotion.stand:
        await _playStand(generation: gen, force: !fromAuto);
      case PetMotion.happy:
        await _playHappy(generation: gen);
      case PetMotion.play:
        await _playPlay(generation: gen);
    }

    if (!fromAuto && gen == _motionGeneration && !isEvent) {
      _manualControl = false;
      if (!_eventMotionActive) {
        _scheduleAutoBehavior(delay: _randomIdleDelay());
      }
    }
  }

  void _scheduleAutoBehavior({required double delay}) {
    if (!_autoBehavior || _manualControl || _assets == null) return;
    if (_eventMotionActive) return;
    _autoTimer?.stop();
    _autoTimer = Timer(
      delay,
      onTick: () {
        if (!isMounted || _manualControl || _eventMotionActive) return;
        unawaited(_runAutoBehavior());
      },
    );
    _autoTimer!.start();
  }

  Future<void> _runAutoBehavior() async {
    if (_manualControl || _assets == null || _eventMotionActive) return;

    if (_isSitting) {
      if (_sittingIdleCycleCount < 1) {
        await playMotion(PetMotion.sittingIdle, fromAuto: true);
        return;
      }
      if (_random.nextDouble() < 0.45) {
        await playMotion(PetMotion.stand, fromAuto: true);
      } else {
        await playMotion(PetMotion.sittingIdle, fromAuto: true);
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
      await playMotion(PetMotion.sit, fromAuto: true);
    }
  }

  Future<void> _enterIdle({
    bool resetAuto = true,
    int? generation,
  }) async {
    if (generation != null && generation != _motionGeneration) return;
    _motion = PetMotion.idle;
    _isSitting = false;
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

  Future<void> _startDirectionalMove(
    PetMotion motion, {
    int? generation,
  }) async {
    if (generation != null && generation != _motionGeneration) return;
    _pendingMoveCycleFinish = false;
    _motion = motion;
    _isSitting = false;
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

  /// walk/run 이동이 끝났을 때, 현재 스프라이트 사이클이 끝난 뒤에만
  /// 다음 반복 또는 idle 로 전환한다.
  Future<void> _finishDirectionalMoveAfterCycle() async {
    if (_pendingMoveCycleFinish) return;
    if (_motion != PetMotion.walk && _motion != PetMotion.run) {
      _stopMovement();
      return;
    }

    _pendingMoveCycleFinish = true;
    final gen = _motionGeneration;
    final motion = _motion;
    final shouldRepeat = _repeatRemaining > 1;
    final resetAuto = !_manualControl;

    // 위치 이동만 멈추고, 현재 walk/run 애니메이션은 사이클 끝까지 유지한다.
    _stopMovement();

    final remaining = _remainingInCurrentAnimationCycle();
    if (remaining > 0.001) {
      await _waitDuration(remaining, generation: gen);
    }

    if (gen != _motionGeneration || !isMounted) {
      _pendingMoveCycleFinish = false;
      return;
    }
    if (_motion != motion) {
      _pendingMoveCycleFinish = false;
      return;
    }

    _pendingMoveCycleFinish = false;

    if (shouldRepeat) {
      _repeatRemaining--;
      await _startDirectionalMove(motion, generation: gen);
    } else if (!_isSitting) {
      await _enterIdle(resetAuto: resetAuto, generation: gen);
    }
  }

  /// 현재 walk/run 루프 애니메이션에서 이번 사이클이 끝나기까지 남은 시간.
  double _remainingInCurrentAnimationCycle() {
    final animation = _animChild?.animation;
    if (animation == null || animation.frames.isEmpty) return 0;
    final cycle = animation.frames.fold<double>(
      0,
      (sum, f) => sum + f.stepTime,
    );
    if (cycle <= 0) return 0;
    final intoCycle = animation.elapsed % cycle;
    final remaining = cycle - intoCycle;
    if (remaining <= 0.0005) return 0;
    return remaining;
  }

  Future<void> _waitDuration(double duration, {int? generation}) async {
    if (duration <= 0) return;
    final completer = Completer<void>();
    _motionTimer?.stop();
    _motionTimer = Timer(
      duration,
      onTick: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
    _motionTimer!.start();
    await completer.future;
    if (generation != null && generation != _motionGeneration) return;
  }

  Future<void> _playSit({int? generation}) async {
    if (generation != null && generation != _motionGeneration) return;
    _motion = PetMotion.sit;
    _stopMovement();
    final anim = _cloneAnimation(_assets!.sitAnimation, loop: false);
    await _showAnimation(anim);
    await _waitForAnimation(anim, generation: generation);
    if (generation != null && generation != _motionGeneration) return;
    _sittingIdleCycleCount = 0;
    await _enterSittingIdle(resetAuto: true, generation: generation);
  }

  Future<void> _enterSittingIdle({
    bool resetAuto = true,
    int? generation,
  }) async {
    if (generation != null && generation != _motionGeneration) return;
    _motion = PetMotion.sittingIdle;
    _isSitting = true;
    _stopMovement();
    _speedMultiplier = kPetMotionDefaultTuningFor(
      PetMotion.sittingIdle,
    ).speedMultiplier.clamp(0.25, 3.0);
    final anim = _cloneAnimation(_assets!.sittingIdleAnimation, loop: true);
    await _showAnimation(anim);

    // 1 cycle 완료 후 카운트 증가
    final cycleTime = anim.frames.fold<double>(0, (s, f) => s + f.stepTime);
    _motionTimer?.stop();
    final gen = generation ?? _motionGeneration;
    _motionTimer = Timer(
      cycleTime,
      onTick: () {
        if (!isMounted || gen != _motionGeneration) return;
        if (_motion == PetMotion.sittingIdle) {
          _sittingIdleCycleCount++;
        }
      },
    );
    _motionTimer!.start();

    if (resetAuto) {
      _scheduleAutoBehavior(delay: 3 + _random.nextDouble() * 5);
    }
  }

  Future<void> _playStand({int? generation, bool force = false}) async {
    if (generation != null && generation != _motionGeneration) return;
    if (!_isSitting) {
      await _enterIdle(generation: generation);
      return;
    }
    if (!force && _sittingIdleCycleCount < 1) {
      debugPrint('[VegePet] stand blocked: sittingIdleCycleCount=0');
      await _enterSittingIdle(resetAuto: true, generation: generation);
      return;
    }

    _motion = PetMotion.stand;
    _stopMovement();
    final anim = _cloneAnimation(_assets!.standAnimation, loop: false);
    await _showAnimation(anim);
    await _waitForAnimation(anim, generation: generation);
    if (generation != null && generation != _motionGeneration) return;
    _isSitting = false;
    _sittingIdleCycleCount = 0;
    await _enterIdle(generation: generation);
  }

  Future<void> _playHappy({int? generation}) async {
    if (generation != null && generation != _motionGeneration) return;
    _eventMotionActive = true;
    _manualControl = true;
    _manualRunActive = false;
    _autoTimer?.stop();
    _stopMovement();
    _motion = PetMotion.happy;

    final wasSitting = _isSitting;
    var remaining = _repeatRemaining;
    while (remaining > 0 && isMounted) {
      if (generation != null && generation != _motionGeneration) {
        _eventMotionActive = false;
        return;
      }
      final anim = _cloneAnimation(_assets!.happyAnimation, loop: false);
      await _showAnimation(anim);
      await _waitForAnimation(anim, generation: generation);
      remaining--;
    }
    if (generation != null && generation != _motionGeneration) {
      _eventMotionActive = false;
      return;
    }

    _eventMotionActive = false;
    _manualControl = false;

    if (isDog) {
      _sittingIdleCycleCount = 0;
      await _enterSittingIdle(resetAuto: true, generation: generation);
    } else if (wasSitting) {
      await _enterSittingIdle(resetAuto: true, generation: generation);
    } else {
      await _enterIdle(resetAuto: true, generation: generation);
    }
  }

  Future<void> _playPlay({int? generation}) async {
    if (generation != null && generation != _motionGeneration) return;
    _eventMotionActive = true;
    _manualControl = true;
    _manualRunActive = false;
    _autoTimer?.stop();
    _stopMovement();
    _motion = PetMotion.play;

    final wasSitting = _isSitting;
    var remaining = _repeatRemaining;
    while (remaining > 0 && isMounted) {
      if (generation != null && generation != _motionGeneration) {
        _eventMotionActive = false;
        return;
      }
      final anim = _cloneAnimation(_assets!.playAnimation, loop: false);
      await _showAnimation(anim);
      await _waitForAnimation(anim, generation: generation);
      remaining--;
    }
    if (generation != null && generation != _motionGeneration) {
      _eventMotionActive = false;
      return;
    }

    _eventMotionActive = false;
    _manualControl = false;

    if (wasSitting) {
      await _enterSittingIdle(resetAuto: true, generation: generation);
    } else {
      await _enterIdle(resetAuto: true, generation: generation);
    }
  }

  Future<void> _showAnimation(SpriteAnimation animation) async {
    _animChild?.removeFromParent();

    for (final frame in animation.frames) {
      frame.stepTime = _assets!.baseStepTime / _speedMultiplier;
    }

    _animChild = SpriteAnimationComponent(
      animation: animation,
      size: Vector2.all(displaySize),
      anchor: Anchor.center,
      position: size / 2,
    );
    add(_animChild!);
    _applyFacingFlip();
  }

  Future<void> _waitForAnimation(
    SpriteAnimation animation, {
    int? generation,
  }) async {
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
    await completer.future;
    if (generation != null && generation != _motionGeneration) return;
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
