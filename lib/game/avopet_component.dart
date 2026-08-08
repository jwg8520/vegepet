import 'dart:async';
import 'dart:math';
import 'dart:ui' show BlurStyle, Canvas, MaskFilter, Offset, Paint, Rect;

import 'package:flame/components.dart';
import 'package:flutter/foundation.dart';
import 'package:avopet/game/pet_collision_tune.dart';
import 'package:avopet/game/pet_motion.dart';
import 'package:avopet/game/pet_shadow_tune.dart';
import 'package:avopet/game/pet_sprite_assets.dart';
import 'package:avopet/game/yard_game.dart';

/// 기본 스폰 위치 (844×390, 오두막 문 앞).
final Vector2 kDefaultPetSpawnPosition = Vector2(380, 250);

/// 하위 호환 alias.
final Vector2 kCatScoBabySpawnPosition = kDefaultPetSpawnPosition;
const double kAvoPetDisplaySize = 72;

/// 발밑 충돌 footprint (이동 차단 전용). sprite 전체 박스가 아니다.
/// 런타임 값은 [PetCollisionTuneConfig] (종×단계). 아래는 기본값 alias.
const double kPetCollisionFootprintW = kPetCollisionDefaultWidth;
const double kPetCollisionFootprintH = kPetCollisionDefaultHeight;
const double kPetCollisionFootprintYOffset = kPetCollisionDefaultOffsetY;

/// 하위 호환 alias.
const double kCatScoBabyCollisionFootprintW = kPetCollisionFootprintW;
const double kCatScoBabyCollisionFootprintH = kPetCollisionFootprintH;
const double kCatScoBabyCollisionFootprintYOffset = kPetCollisionFootprintYOffset;

/// walk / run 이동 속도 (논리 px/sec).
const double kAvoPetWalkSpeed = 38;
const double kAvoPetRunSpeed = 72;

/// 펫 렌더 우선순위 베이스. 발 y 를 더해 아래쪽 펫이 앞에 오도록 한다.
/// (지면 2·연기 3 위, 하트 이펙트보다 아래)
const int kAvoPetPriorityBase = 100;
const int kAvoPetPriorityYSpan = 500;

typedef PetMoveValidator = bool Function(Vector2 current, Vector2 next);

typedef PetFootprintMoveValidator =
    bool Function(List<Vector2> currentPoints, List<Vector2> nextPoints);

final List<Vector2> kAvoPetEightDirections = [
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
class AvoPetComponent extends PositionComponent
    with HasGameReference<YardGame> {
  AvoPetComponent({
    required this.userPetId,
    required this.speciesCode,
    required this.stage,
    required this.canMoveFootprintTo,
    this.isDebugOnly = false,
    this.isResident = false,
    this.seedRandomAmbient = false,
    Vector2? initialPosition,
  }) : displaySize = petDisplaySizeForStage(stage),
       stageFolder = petStageAssetFolder(stage),
       super(
         position: initialPosition ?? kDefaultPetSpawnPosition.clone(),
         anchor: Anchor.bottomCenter,
         size: Vector2.all(petDisplaySizeForStage(stage)),
         // 발 y 기준 정렬. update 에서 갱신 (아래쪽 펫이 위쪽 펫·그림자 앞에).
         priority: kAvoPetPriorityBase +
             (initialPosition ?? kDefaultPetSpawnPosition).y.round().clamp(
               0,
               kAvoPetPriorityYSpan,
             ),
       );

  final String userPetId;
  final String speciesCode;
  String stage;
  String stageFolder;
  double displaySize;
  final PetFootprintMoveValidator canMoveFootprintTo;
  final bool isDebugOnly;
  bool isResident;

  /// true 이면 onLoad 시 위치·일상 모션을 랜덤으로 시드 (happy/play 제외).
  final bool seedRandomAmbient;

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

  /// play 종료 후, 또는 고양이 happy 종료 후: 다음 자동 행동은 최소 1회 idle 강제.
  bool _forceIdleOnce = false;

  /// 강아지 play 이동: 현재 좌/우 바라본 채 연속 재생한 사이클 수.
  int _dogPlaySameFacingCycles = 0;
  bool? _dogPlayFacingLeft;

  Vector2 _moveDirection = Vector2.zero();
  double _moveSpeed = kAvoPetWalkSpeed;
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
    final tune = game.petCollisionTuneFor(
      speciesCode: speciesCode,
      stage: stage,
    );
    final cx = position.x + tune.offsetX;
    final cy = position.y + tune.offsetY;
    return Rect.fromCenter(
      center: Offset(cx, cy),
      width: tune.width,
      height: tune.height,
    );
  }

  List<Vector2> get collisionSamplePoints => collisionSamplePointsAt(position);

  List<Vector2> collisionSamplePointsAt(Vector2 footPos) {
    final tune = game.petCollisionTuneFor(
      speciesCode: speciesCode,
      stage: stage,
    );
    final cx = footPos.x + tune.offsetX;
    final cy = footPos.y + tune.offsetY;
    final hw = tune.width / 2;
    final hh = tune.height / 2;
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
    final tune = game.petShadowTuneFor(
      speciesCode: speciesCode,
      stage: stage,
    );
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
      'AvoPetComponent onLoad: id=$userPetId species=$speciesCode '
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
    if (seedRandomAmbient) {
      await _applyRandomAmbientPresence();
    } else {
      _facingLeft = true;
      await _enterIdle(resetAuto: false);
      _scheduleAutoBehavior(delay: _randomIdleDelay());
    }
  }

  /// 앱 재진입 등: 걸을 수 있는 랜덤 위치 + happy/play 제외 일상 모션.
  Future<void> _applyRandomAmbientPresence() async {
    _relocateToRandomWalkablePosition();
    _facingLeft = _random.nextBool();
    _applyFacingFlip();
    await _startRandomAmbientMotion();
  }

  void _relocateToRandomWalkablePosition() {
    const attempts = 48;
    final minX = 48.0;
    final maxX = YardGame.gameWidth - 48.0;
    final minY = 170.0;
    final maxY = YardGame.gameHeight - 36.0;
    if (maxX <= minX || maxY <= minY) return;

    for (var i = 0; i < attempts; i++) {
      final candidate = Vector2(
        minX + _random.nextDouble() * (maxX - minX),
        minY + _random.nextDouble() * (maxY - minY),
      );
      final samples = collisionSamplePointsAt(candidate);
      if (canMoveFootprintTo(samples, samples)) {
        position.setFrom(candidate);
        _syncRenderPriorityByY();
        return;
      }
    }
  }

  Future<void> _startRandomAmbientMotion() async {
    final roll = _random.nextDouble();
    if (roll < 0.28) {
      await _enterIdle(resetAuto: true);
    } else if (roll < 0.50) {
      await playMotion(
        PetMotion.walk,
        fromAuto: true,
        repeatCount: 1 + _random.nextInt(2),
      );
    } else if (roll < 0.68) {
      await playMotion(PetMotion.run, fromAuto: true, repeatCount: 1);
    } else if (roll < 0.86) {
      await playMotion(PetMotion.sit, fromAuto: true);
    } else {
      // 이미 앉아 있는 것처럼 보이게 sittingIdle 로 시작.
      _sittingIdleCycleCount = 1;
      await _enterSittingIdle(resetAuto: true);
    }
  }

  /// 성장 단계 asset 을 제거/재스폰 없이 제자리에서 교체한다.
  /// 위치·진행 중 모션을 유지하고, 새 단계 스프라이트로 같은 모션을 최소 1사이클 이어간다.
  Future<void> applyStageInPlace(String newStage) async {
    final normalized = newStage;
    final newFolder = petStageAssetFolder(normalized);
    final newSize = petDisplaySizeForStage(normalized);

    stage = normalized;
    if (newFolder == stageFolder && (newSize - displaySize).abs() < 0.01) {
      return;
    }

    // 진행 상태 스냅샷 (애셋 로드 전·후 모두 동일하게 복원).
    final keepPos = position.clone();
    final keepFacing = _facingLeft;
    final keepMotion = _motion;
    final keepSitting = _isSitting;
    final keepSittingIdleCycles = _sittingIdleCycleCount;
    final keepMoving = _isMoving;
    final keepMoveDir = _moveDirection.clone();
    final keepMoveSpeed = _moveSpeed;
    final keepMoveTimeLeft = _moveTimeLeft;
    final keepManual = _manualControl;
    final keepManualRun = _manualRunActive;
    final keepEvent = _eventMotionActive;
    final keepRepeat = max(1, _repeatRemaining);
    final keepForceIdle = _forceIdleOnce;
    final keepDogPlayCycles = _dogPlaySameFacingCycles;
    final keepDogPlayFacing = _dogPlayFacingLeft;

    // 진행 중 await 를 끊되, 비주얼(size/anim)은 새 애셋 준비 전까지 건드리지 않는다.
    // (size 를 먼저 키우면 bottomCenter 기준 young 스프라이트가 위로 튀는 것처럼 보임)
    _autoTimer?.stop();
    _motionTimer?.stop();
    final gen = ++_motionGeneration;
    _pendingMoveCycleFinish = false;

    stageFolder = newFolder;
    await PetSpriteAssets.preflightAssets(
      game,
      speciesCode: speciesCode,
      stageFolder: stageFolder,
    );
    final loaded = await PetSpriteAssets.load(
      game,
      speciesCode: speciesCode,
      stageFolder: stageFolder,
    );
    if (!isMounted || gen != _motionGeneration) return;

    // 애셋·크기·애니메이션을 한 번에 교체 (발 위치 keepPos 유지).
    _assets = loaded;
    displaySize = newSize;
    size = Vector2.all(displaySize);
    position.setFrom(keepPos);

    _facingLeft = keepFacing;
    _isSitting = keepSitting;
    _sittingIdleCycleCount = keepSittingIdleCycles;
    _manualControl = keepManual;
    _manualRunActive = keepManualRun;
    _eventMotionActive = keepEvent;
    _forceIdleOnce = keepForceIdle;
    _dogPlaySameFacingCycles = keepDogPlayCycles;
    _dogPlayFacingLeft = keepDogPlayFacing;
    _repeatRemaining = keepRepeat;
    _moveDirection = keepMoveDir;
    _moveSpeed = keepMoveSpeed;
    _moveTimeLeft = keepMoveTimeLeft;
    _isMoving = keepMoving && !keepMoveDir.isZero();

    final tune = game.petMotionTuneFor(
      speciesCode: speciesCode,
      stage: stage,
      motion: keepMotion,
    );
    _speedMultiplier = tune.speedMultiplier.clamp(0.25, 3.0);

    await _continueMotionAfterStageSwap(
      motion: keepMotion,
      generation: gen,
    );
  }

  /// 단계 교체 직후: 스냅샷한 모션을 새 스프라이트로 최소 1사이클 이어 재생.
  Future<void> _continueMotionAfterStageSwap({
    required PetMotion motion,
    required int generation,
  }) async {
    if (!isMounted || generation != _motionGeneration || _assets == null) {
      return;
    }

    switch (motion) {
      case PetMotion.idle:
        await _enterIdle(resetAuto: false, generation: generation);
        if (generation != _motionGeneration || !isMounted) return;
        if (!_manualControl && !_eventMotionActive) {
          final cycle = _animationCycleDuration(_assets!.idleAnimation);
          _scheduleAutoBehavior(
            delay: max(_randomIdleDelay(), cycle),
          );
        }
      case PetMotion.walk:
      case PetMotion.run:
        await _resumeDirectionalMoveAfterStageSwap(
          motion,
          generation: generation,
        );
      case PetMotion.sit:
        _repeatRemaining = max(1, _repeatRemaining);
        await _playSit(generation: generation);
      case PetMotion.sittingIdle:
        await _enterSittingIdle(resetAuto: true, generation: generation);
      case PetMotion.stand:
        await _playStand(generation: generation, force: true);
      case PetMotion.happy:
        _eventMotionActive = true;
        _manualControl = true;
        _autoTimer?.stop();
        _repeatRemaining = max(1, _repeatRemaining);
        await _playHappy(generation: generation);
      case PetMotion.play:
        _eventMotionActive = true;
        _manualControl = true;
        _autoTimer?.stop();
        _repeatRemaining = max(1, _repeatRemaining);
        await _playPlay(generation: generation);
    }
  }

  Future<void> _resumeDirectionalMoveAfterStageSwap(
    PetMotion motion, {
    required int generation,
  }) async {
    if (generation != _motionGeneration || _assets == null) return;
    if (motion != PetMotion.walk && motion != PetMotion.run) return;

    _motion = motion;
    _isSitting = false;
    _pendingMoveCycleFinish = false;
    _moveSpeed =
        motion == PetMotion.run ? kAvoPetRunSpeed : kAvoPetWalkSpeed;

    if (_moveDirection.isZero()) {
      _moveDirection =
          kAvoPetEightDirections[_random.nextInt(
            kAvoPetEightDirections.length,
          )];
    }
    _updateFacingFromDirection(_moveDirection);
    _isMoving = true;

    final source = motion == PetMotion.run
        ? _assets!.runAnimation
        : _assets!.walkAnimation;
    final anim = _cloneAnimation(source, loop: true);
    await _showAnimation(anim);
    if (generation != _motionGeneration || !isMounted) return;

    // 새 단계 스프라이트로 최소 1사이클은 이동·모션 유지.
    final cycle = _animationCycleDuration(anim);
    if (_moveTimeLeft < cycle) {
      _moveTimeLeft = cycle;
    }
    _repeatRemaining = max(1, _repeatRemaining);
  }

  double _animationCycleDuration(SpriteAnimation animation) {
    if (animation.frames.isEmpty) return 0.14;
    return animation.frames.fold<double>(0, (sum, f) => sum + f.stepTime);
  }

  @override
  void onRemove() {
    _autoTimer?.stop();
    _motionTimer?.stop();
    _motionGeneration++;
    super.onRemove();
  }

  /// 발 위치(y)가 클수록 앞에 그려 아래쪽 펫·그림자가 위쪽 펫을 가리게 한다.
  void _syncRenderPriorityByY() {
    final next =
        kAvoPetPriorityBase +
        position.y.round().clamp(0, kAvoPetPriorityYSpan);
    if (priority != next) {
      priority = next;
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    _syncRenderPriorityByY();
    if (_assets == null) return;

    final scaledDt = dt * _speedMultiplier;

    _autoTimer?.update(scaledDt);
    _motionTimer?.update(scaledDt);

    if (_isMoving) {
      if (!_pendingMoveCycleFinish && _moveTimeLeft > 0) {
        _moveTimeLeft -= scaledDt;
      }

      // 사이클 마무리 중에도 이동을 유지해 제자리 뛰기처럼 보이지 않게 한다.
      if ((_moveTimeLeft > 0 || _pendingMoveCycleFinish) &&
          !_moveDirection.isZero()) {
        _moveWithCollision(scaledDt);
      }

      if (!_pendingMoveCycleFinish &&
          _isMoving &&
          _moveTimeLeft <= 0) {
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

    // 강아지 play 이동 중 장애물: 최소 2사이클 규칙 예외 — 즉시 방향 전환 허용.
    if (_motion == PetMotion.play && isDog) {
      final newDirection = _pickAlternativeDirection(current);
      if (newDirection != null) {
        _moveDirection = newDirection;
        _updateFacingFromDirection(_moveDirection);
        _dogPlaySameFacingCycles = 1;
        _dogPlayFacingLeft = _facingLeft;
        return;
      }
      _stopMovement();
      return;
    }

    final newDirection = _pickAlternativeDirection(current);
    if (newDirection != null) {
      _moveDirection = newDirection;
      _updateFacingFromDirection(_moveDirection);
      return;
    }

    // 더 이상 진행 불가: 제자리 walk/run 사이클 대기 없이 즉시 idle.
    _stopMovement();
    _pendingMoveCycleFinish = false;
    _motionTimer?.stop();
    if (_motion == PetMotion.walk || _motion == PetMotion.run) {
      final resetAuto = !_manualControl;
      _motionGeneration++;
      unawaited(_enterIdle(resetAuto: resetAuto));
    }
  }

  Vector2? _pickAlternativeDirection(Vector2 current) {
    const probe = 6.0;

    final candidates = <Vector2>[];
    if (!_moveDirection.isZero()) {
      candidates.add(-_moveDirection);
    }
    candidates.addAll(
      List<Vector2>.from(kAvoPetEightDirections)..shuffle(_random),
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
      debugPrint('[AvoPet] manual run ignored (sitting/event)');
      return;
    }

    _manualControl = true;
    _manualRunActive = true;
    _autoTimer?.stop();
    _motionGeneration++;

    _speedMultiplier = speedMultiplier.clamp(0.25, 3.0);
    _motion = PetMotion.run;
    _moveSpeed = kAvoPetRunSpeed;
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
        debugPrint('[AvoPet] $motion blocked while sitting');
        _scheduleAutoBehavior(delay: _randomIdleDelay());
        return;
      }
      if (motion == PetMotion.idle ||
          motion == PetMotion.walk ||
          motion == PetMotion.run) {
        debugPrint('[AvoPet] $motion blocked while sitting');
        return;
      }
    }

    // sit 직후 sittingIdle 최소 1회 전 stand 금지 (디버그 stand 는 강제 허용)
    if (motion == PetMotion.stand &&
        _isSitting &&
        _sittingIdleCycleCount < 1 &&
        fromAuto) {
      debugPrint('[AvoPet] stand blocked until sittingIdle >= 1');
      await _enterSittingIdle(resetAuto: true);
      return;
    }

    final defaults = game.petMotionTuneFor(
      speciesCode: speciesCode,
      stage: stage,
      motion: motion,
    );
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
      // idle 강제 대기 중이면 일어서서 idle 경로로 보낸다.
      if (_forceIdleOnce) {
        await playMotion(PetMotion.stand, fromAuto: true);
        return;
      }
      if (_random.nextDouble() < 0.45) {
        await playMotion(PetMotion.stand, fromAuto: true);
      } else {
        await playMotion(PetMotion.sittingIdle, fromAuto: true);
      }
      return;
    }

    // play/고양이 happy 직후 다음 자동 동작은 반드시 idle 1회.
    if (_forceIdleOnce) {
      _forceIdleOnce = false;
      await playMotion(PetMotion.idle, fromAuto: true);
      _scheduleAutoBehavior(delay: 2 + _random.nextDouble() * 3);
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
    _speedMultiplier = game
        .petMotionTuneFor(
          speciesCode: speciesCode,
          stage: stage,
          motion: PetMotion.idle,
        )
        .speedMultiplier
        .clamp(0.25, 3.0);
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
    _moveSpeed = motion == PetMotion.run ? kAvoPetRunSpeed : kAvoPetWalkSpeed;

    _moveDirection =
        kAvoPetEightDirections[_random.nextInt(
          kAvoPetEightDirections.length,
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
  ///
  /// 사이클이 끝나기 전에는 이동을 유지한다(중간에 멈춰 제자리 뛰기 방지).
  /// [keepMoving] false 는 충돌로 더 이상 진행 불가할 때만 사용한다.
  Future<void> _finishDirectionalMoveAfterCycle({
    bool keepMoving = true,
  }) async {
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

    final canKeepMoving = keepMoving && !_moveDirection.isZero();
    if (canKeepMoving) {
      _isMoving = true;
    } else {
      _stopMovement();
    }

    // 고양이 run → idle 직전 마지막만 4프레임(0~3)에서 컷. 중간 루프는 5프레임 유지.
    // 강아지 run → idle 직전 마지막만 3프레임(0~2)에서 컷. 중간 루프는 4프레임 유지.
    final useCatRunIdleCutoff =
        !shouldRepeat && motion == PetMotion.run && isCat;
    final useDogRunIdleCutoff =
        !shouldRepeat && motion == PetMotion.run && isDog;
    final remaining = useCatRunIdleCutoff
        ? _remainingUntilCatRunFourFrameCutoff()
        : useDogRunIdleCutoff
        ? _remainingUntilDogRunThreeFrameCutoff()
        : _remainingInCurrentAnimationCycle();
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

    _stopMovement();
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
    final elapsed = _animChild?.animationTicker?.elapsed ?? 0.0;
    final intoCycle = elapsed % cycle;
    final remaining = cycle - intoCycle;
    if (remaining <= 0.0005) return 0;
    return remaining;
  }

  /// 고양이 run idle 전환용: 5프레임 사이클에서 4프레임(인덱스 0~3) 끝까지만 대기.
  double _remainingUntilCatRunFourFrameCutoff() {
    final animation = _animChild?.animation;
    if (animation == null || animation.frames.length < 5) {
      return _remainingInCurrentAnimationCycle();
    }
    final cycle = animation.frames.fold<double>(
      0,
      (sum, f) => sum + f.stepTime,
    );
    if (cycle <= 0) return 0;
    final cutoff = animation.frames
        .take(4)
        .fold<double>(0, (sum, f) => sum + f.stepTime);
    final elapsed = _animChild?.animationTicker?.elapsed ?? 0.0;
    final intoCycle = elapsed % cycle;
    // 이미 5번째 프레임 구간이면 즉시 idle.
    if (intoCycle >= cutoff - 0.0005) return 0;
    return cutoff - intoCycle;
  }

  /// 강아지 run idle 전환용: 4프레임 사이클에서 3프레임(인덱스 0~2) 끝까지만 대기.
  double _remainingUntilDogRunThreeFrameCutoff() {
    final animation = _animChild?.animation;
    if (animation == null || animation.frames.length < 4) {
      return _remainingInCurrentAnimationCycle();
    }
    final cycle = animation.frames.fold<double>(
      0,
      (sum, f) => sum + f.stepTime,
    );
    if (cycle <= 0) return 0;
    final cutoff = animation.frames
        .take(3)
        .fold<double>(0, (sum, f) => sum + f.stepTime);
    final elapsed = _animChild?.animationTicker?.elapsed ?? 0.0;
    final intoCycle = elapsed % cycle;
    // 이미 4번째 프레임 구간이면 즉시 idle.
    if (intoCycle >= cutoff - 0.0005) return 0;
    return cutoff - intoCycle;
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
    _speedMultiplier = game
        .petMotionTuneFor(
          speciesCode: speciesCode,
          stage: stage,
          motion: PetMotion.sittingIdle,
        )
        .speedMultiplier
        .clamp(0.25, 3.0);
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
      debugPrint('[AvoPet] stand blocked: sittingIdleCycleCount=0');
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
      // generation 불일치 시 플래그를 건드리지 않음 — 단계 교체 후 재개 루틴이 소유권을 가짐.
      if (generation != null && generation != _motionGeneration) {
        return;
      }
      final anim = _cloneAnimation(_assets!.happyAnimation, loop: false);
      await _showAnimation(anim);
      await _waitForAnimation(anim, generation: generation);
      remaining--;
    }
    if (generation != null && generation != _motionGeneration) {
      return;
    }

    _eventMotionActive = false;
    _manualControl = false;

    // 고양이: happy 종료 후 반드시 idle(최소 1회). 앉은 상태여도 sittingIdle로 복귀하지 않음.
    if (isCat) {
      _forceIdleOnce = true;
      await _enterIdle(resetAuto: true, generation: generation);
      return;
    }

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

    if (isDog) {
      await _playDogPlayMoving(generation: generation);
    } else {
      var remaining = _repeatRemaining;
      while (remaining > 0 && isMounted) {
        // generation 불일치 시 플래그를 건드리지 않음 — 단계 교체 후 재개 루틴이 소유권을 가짐.
        if (generation != null && generation != _motionGeneration) {
          return;
        }
        final anim = _cloneAnimation(_assets!.playAnimation, loop: false);
        await _showAnimation(anim);
        await _waitForAnimation(anim, generation: generation);
        remaining--;
      }
    }

    if (generation != null && generation != _motionGeneration) {
      return;
    }

    _eventMotionActive = false;
    _manualControl = false;

    // play 종료 후 반드시 idle(최소 1회).
    _forceIdleOnce = true;
    await _enterIdle(resetAuto: true, generation: generation);
  }

  /// 강아지 play: run 속도로 이동하며 사이클마다 방향 랜덤.
  /// 같은 좌/우를 최소 2사이클 본 뒤에만 반대 방향이 랜덤 후보에 포함.
  /// 장애물 충돌 시에는 즉시 방향 전환 허용(_handleMoveBlocked).
  Future<void> _playDogPlayMoving({int? generation}) async {
    if (_assets == null) return;
    _isSitting = false;
    _dogPlaySameFacingCycles = 0;
    _dogPlayFacingLeft = null;
    _moveSpeed = kAvoPetRunSpeed;
    _moveTimeLeft = double.infinity;
    _pendingMoveCycleFinish = false;

    var remaining = _repeatRemaining;
    while (remaining > 0 && isMounted) {
      if (generation != null && generation != _motionGeneration) {
        _stopMovement();
        return;
      }

      final allowFacingFlip = _dogPlaySameFacingCycles >= 2;
      _assignDogPlayMoveDirection(allowFacingFlip: allowFacingFlip);
      _isMoving = true;
      _moveTimeLeft = double.infinity;

      final facingBefore = _dogPlayFacingLeft;
      _updateFacingFromDirection(_moveDirection);
      if (facingBefore == null || facingBefore == _facingLeft) {
        _dogPlaySameFacingCycles =
            facingBefore == null ? 1 : _dogPlaySameFacingCycles + 1;
      } else {
        _dogPlaySameFacingCycles = 1;
      }
      _dogPlayFacingLeft = _facingLeft;

      final anim = _cloneAnimation(_assets!.playAnimation, loop: false);
      await _showAnimation(anim);
      await _waitForAnimation(anim, generation: generation);
      remaining--;
    }

    _stopMovement();
    _dogPlaySameFacingCycles = 0;
    _dogPlayFacingLeft = null;
  }

  void _assignDogPlayMoveDirection({required bool allowFacingFlip}) {
    final shuffled = List<Vector2>.from(kAvoPetEightDirections)
      ..shuffle(_random);

    Vector2? pickFrom(Iterable<Vector2> dirs, {required bool requireReachable}) {
      for (final dir in dirs) {
        if (dir.isZero()) continue;
        if (!allowFacingFlip && _dogPlayDirectionWouldFlipFacing(dir)) {
          continue;
        }
        if (requireReachable && !_dogPlayDirectionReachable(dir)) continue;
        return dir.clone();
      }
      return null;
    }

    final chosen =
        pickFrom(shuffled, requireReachable: true) ??
        pickFrom(shuffled, requireReachable: false) ??
        kAvoPetEightDirections[_random.nextInt(kAvoPetEightDirections.length)]
            .clone();

    _moveDirection = chosen;
  }

  bool _dogPlayDirectionWouldFlipFacing(Vector2 dir) {
    if (dir.x.abs() <= 0.01) return false;
    final wouldFaceLeft = dir.x < -0.01;
    return wouldFaceLeft != _facingLeft;
  }

  bool _dogPlayDirectionReachable(Vector2 dir) {
    const probe = 6.0;
    final current = position.clone();
    final next = current + dir * probe;
    return canMoveFootprintTo(
      collisionSamplePointsAt(current),
      collisionSamplePointsAt(next),
    );
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
