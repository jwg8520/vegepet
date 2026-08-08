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

  /// sprite/idle 준비 + world mount 완료 여부.
  /// collision debug / sync 성공 판정은 이 플래그를 기준으로 한다.
  ///
  /// Flame 의 [Component.add] 는 onLoad 까지만 await 하고 mount 는 다음
  /// game tick 이므로, visualReady 는 [onMount] 에서 확정한다.
  bool _visualReady = false;
  final Completer<void> _visualReadyCompleter = Completer<void>();

  /// onLoad 에서 idle 까지 끝난 뒤, onMount 에서 ambient bootstrap 할지.
  bool _pendingAmbientBootstrap = false;

  bool get isVisualReady =>
      _visualReady && _assets != null && _animChild != null && isMounted;

  Future<void> get whenVisualReady {
    if (isVisualReady) return Future<void>.value();
    return _visualReadyCompleter.future;
  }

  void _markVisualReady() {
    if (_visualReady) return;
    _visualReady = true;
    if (!_visualReadyCompleter.isCompleted) {
      _visualReadyCompleter.complete();
    }
  }

  void _failVisualReady(Object error, StackTrace stackTrace) {
    if (!_visualReadyCompleter.isCompleted) {
      _visualReadyCompleter.completeError(error, stackTrace);
    }
  }

  /// mount 전에 abort/discard 될 때 onRemove 가 호출되지 않을 수 있으므로
  /// spawn 측에서 명시적으로 completer 를 실패시킨다.
  void notifySpawnAborted([Object? error]) {
    _failVisualReady(
      error ?? StateError('AvoPetComponent spawn aborted before visualReady'),
      StackTrace.current,
    );
  }

  /// 자동 ambient 일반 idle_sheet: 1회 발동당 최대 cycle 수.
  static const int kMaxConsecutiveIdleReps = 8;

  /// 현재 idle 발동(bout)에서 재생한 cycle 수.
  /// happy/play/sittingIdle 및 수동 debug motion 은 집계하지 않는다.
  int _consecutiveIdleReps = 0;

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
    try {
      // load() 가 필수 시트를 모두 읽으므로 중복 preflight 로 cold-start 를 늘리지 않는다.
      _assets = await PetSpriteAssets.load(
        game,
        speciesCode: speciesCode,
        stageFolder: stageFolder,
      );
      size = Vector2.all(displaySize);
      if (seedRandomAmbient) {
        // cold-start: 랜덤 위치 + idle 준비. ambient 는 onMount 이후.
        _relocateToRandomWalkablePosition();
        _facingLeft = _random.nextBool();
      } else {
        // 신규 분양 등: 오두막 앞(또는 지정) 위치 유지. ambient 는 onMount 이후.
        // seedRandomAmbient 는 "랜덤 배치"만 끄며 ambient loop 자체를 끄지 않는다.
        _facingLeft = true;
      }
      // visualReady 전(onLoad)에 idle bout/timer 를 돌리면 mount 전 generation
      // 경합으로 ambient 가 영구히 끊길 수 있어, 양쪽 모두 mount 후 bootstrap.
      await _enterIdle(resetAuto: false);
      _pendingAmbientBootstrap = true;
      debugPrint(
        'AvoPetComponent onLoad done: id=$userPetId '
        'assets=${_assets != null} anim=${_animChild != null} '
        'seedAmbient=$seedRandomAmbient',
      );
    } catch (e, st) {
      _failVisualReady(e, st);
      rethrow;
    }
  }

  @override
  void onMount() {
    super.onMount();
    // 최소 readiness: 필수 sprite/idle + mount. ambient walk/run 은 포함하지 않는다.
    if (_assets != null && _animChild != null) {
      _markVisualReady();
      debugPrint(
        'AvoPetComponent visualReady: id=$userPetId',
      );
      // footprint 확정 직후: obstacle 겹침이면 최근접 안전 위치로 최소 보정.
      resolveCollisionOverlapIfNeeded();
      if (_pendingAmbientBootstrap) {
        _pendingAmbientBootstrap = false;
        // Flame 은 onMount() 반환 뒤에야 isMounted 비트를 켠다.
        // 여기서 바로 bootstrap 하면 `if (!isMounted) return` 에 걸려
        // cold-start ambient 루프가 영구히 시작되지 않는다.
        scheduleMicrotask(() {
          if (!isMounted || _assets == null) return;
          // mount 비트 확정 후 한 번 더 검사 (tune/mask 준비 타이밍).
          resolveCollisionOverlapIfNeeded();
          debugPrint(
            'AvoPetComponent ambient bootstrap start: id=$userPetId',
          );
          unawaited(_bootstrapAmbientAfterVisualReady());
        });
      }
    } else {
      _failVisualReady(
        StateError(
          'AvoPetComponent mounted without assets/anim '
          '(assets=${_assets != null}, anim=${_animChild != null})',
        ),
        StackTrace.current,
      );
    }
  }

  /// cold-start / fresh-adopt 공통: visualReady(mount) 이후 일상 모션을 시작한다.
  Future<void> _bootstrapAmbientAfterVisualReady() async {
    if (!isMounted || _assets == null) return;
    try {
      await _startRandomAmbientMotion();
    } catch (e, st) {
      debugPrint(
        'AvoPetComponent ambient bootstrap failed id=$userPetId: $e\n$st',
      );
      if (!isMounted || _assets == null) return;
      if (_animChild == null) {
        await _enterIdle(resetAuto: true);
      } else {
        _scheduleAutoBehavior(delay: _randomIdleDelay());
      }
    }
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

  /// 현재 footprint 가 마당 mask 와 겹치면 최근접 안전 발 위치로 최소 보정한다.
  /// 정상 위치면 no-op. recovery 후에도 이동은 기존 collision 판정을 그대로 쓴다.
  ///
  /// 반환: 보정 거리(px). 보정 없으면 0.
  double resolveCollisionOverlapIfNeeded({String? reason}) {
    if (!_isFootprintOverlappingMaskAt(position)) return 0;
    final from = position.clone();
    final safe = _findNearestClearFootPosition();
    if (safe == null) {
      debugPrint(
        'AvoPetComponent collision recovery failed id=$userPetId '
        'pos=$position reason=${reason ?? '-'}',
      );
      return 0;
    }
    final distance = from.distanceTo(safe);
    debugPrint(
      'AvoPetComponent collision recovery id=$userPetId '
      'from=$from to=$safe distance=${distance.toStringAsFixed(1)} '
      'reason=${reason ?? '-'}',
    );
    position.setFrom(safe);
    _syncRenderPriorityByY();
    return distance;
  }

  bool _isFootprintOverlappingMaskAt(Vector2 footPos) {
    return collisionSamplePointsAt(footPos).any(game.isInsideCollisionMask);
  }

  bool _isFootprintFullyClearAt(Vector2 footPos) {
    final samples = collisionSamplePointsAt(footPos);
    if (samples.any(game.isInsideCollisionMask)) return false;
    return canMoveFootprintTo(samples, samples);
  }

  /// 현재 위치에서 가까운 순으로 안전(footprint clear) 발 위치를 찾는다.
  Vector2? _findNearestClearFootPosition() {
    if (_isFootprintFullyClearAt(position)) return position.clone();

    const minX = 48.0;
    final maxX = YardGame.gameWidth - 48.0;
    const minY = 170.0;
    final maxY = YardGame.gameHeight - 36.0;

    // 가까운 반경부터 확장. stage footprint 소폭 증가에 대비해 촘촘히.
    const radii = <double>[2, 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64];
    const angles = 24;

    Vector2? best;
    var bestDist2 = double.infinity;

    for (final radius in radii) {
      for (var a = 0; a < angles; a++) {
        final theta = (a / angles) * pi * 2;
        final candidate = Vector2(
          (position.x + cos(theta) * radius).clamp(minX, maxX),
          (position.y + sin(theta) * radius).clamp(minY, maxY),
        );
        if (!_isFootprintFullyClearAt(candidate)) continue;
        final d2 = candidate.distanceToSquared(position);
        if (d2 < bestDist2) {
          bestDist2 = d2;
          best = candidate;
        }
      }
      if (best != null) {
        // 현재 반경에서 이미 최근접을 찾았으면 더 먼 반경은 불필요.
        return best;
      }
    }
    return best;
  }

  Future<void> _startRandomAmbientMotion() async {
    final roll = _random.nextDouble();
    if (roll < 0.28) {
      await _playAutoIdleBout();
    } else if (roll < 0.50) {
      _resetConsecutiveIdleReps();
      await playMotion(
        PetMotion.walk,
        fromAuto: true,
        repeatCount: 1 + _random.nextInt(2),
      );
    } else if (roll < 0.68) {
      _resetConsecutiveIdleReps();
      await playMotion(PetMotion.run, fromAuto: true, repeatCount: 1);
    } else if (roll < 0.86) {
      _resetConsecutiveIdleReps();
      await playMotion(PetMotion.sit, fromAuto: true);
    } else {
      // 이미 앉아 있는 것처럼 보이게 sittingIdle 로 시작.
      _sittingIdleCycleCount = 1;
      await _enterSittingIdle(resetAuto: true);
    }
  }

  /// 성장 단계 asset 을 제거/재스폰 없이 제자리에서 교체한다.
  ///
  /// 마당 발 위치(world foot = [position], anchor bottomCenter)를 유지한다.
  /// 새 stage footprint 가 mask 와 겹칠 때만 최근접 안전 위치로 최소 보정한다.
  /// 이동 중 성장이면 stale motion callback 을 끊고 idle → ambient 로 재시작한다.
  Future<void> applyStageInPlace(String newStage) async {
    final normalized = newStage;
    final newFolder = petStageAssetFolder(normalized);
    final newSize = petDisplaySizeForStage(normalized);
    final oldStage = stage;
    final oldFoot = position.clone();
    final oldComponentPos = position.clone();

    // adult ↔ teen 등 asset/size 동일하면 stage 문자열만 맞추고 위치는 그대로.
    if (newFolder == stageFolder && (newSize - displaySize).abs() < 0.01) {
      stage = normalized;
      return;
    }

    // 진행 중 모션/이동을 먼저 끊는다 (stale timer 가 새 stage 위치를 덮지 않게).
    _autoTimer?.stop();
    _motionTimer?.stop();
    final gen = ++_motionGeneration;
    _pendingMoveCycleFinish = false;
    _isMoving = false;
    _moveTimeLeft = 0;
    _moveDirection.setZero();
    _manualControl = false;
    _manualRunActive = false;
    _eventMotionActive = false;
    _forceIdleOnce = false;
    final keepFacing = _facingLeft;

    stage = normalized;
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

    // 애셋·크기·애니메이션을 한 번에 교체 (발 위치 oldFoot 유지).
    _assets = loaded;
    displaySize = newSize;
    size = Vector2.all(displaySize);
    position.setFrom(oldFoot);
    _facingLeft = keepFacing;

    final blockedBeforeRecovery = _isFootprintOverlappingMaskAt(position);
    final recoveryDistance = resolveCollisionOverlapIfNeeded(
      reason: 'stage:$oldStage->$normalized',
    );
    final finalFoot = position.clone();

    debugPrint(
      'Pet stage transition: id=$userPetId species=$speciesCode '
      '$oldStage -> $normalized reused=true '
      'oldFoot=$oldFoot oldComponentPosition=$oldComponentPos '
      'newFootBeforeRecovery=$oldFoot '
      'newFootprintBlocked=$blockedBeforeRecovery '
      'recoveryApplied=${recoveryDistance > 0} '
      'recoveryDistance=${recoveryDistance.toStringAsFixed(1)} '
      'finalFoot=$finalFoot',
    );

    final tune = game.petMotionTuneFor(
      speciesCode: speciesCode,
      stage: stage,
      motion: PetMotion.idle,
    );
    _speedMultiplier = tune.speedMultiplier.clamp(0.25, 3.0);

    // stage 전환 후: 동일 발 위치에서 idle → ambient 재시작.
    await _enterIdle(resetAuto: false, generation: gen);
    if (!isMounted || gen != _motionGeneration) return;
    _resetConsecutiveIdleReps();
    if (!_manualControl && !_eventMotionActive) {
      _scheduleAutoBehavior(delay: _randomIdleDelay());
    }
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
    if (!_visualReady && !_visualReadyCompleter.isCompleted) {
      _visualReadyCompleter.completeError(
        StateError('AvoPetComponent removed before visualReady'),
        StackTrace.current,
      );
    }
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

    // play/고양이 happy 직후 다음 자동 동작은 반드시 idle 1회(최대 8 cycle bout).
    if (_forceIdleOnce) {
      _forceIdleOnce = false;
      await _playAutoIdleBout();
      return;
    }

    final roll = _random.nextDouble();
    if (roll < 0.30) {
      await _playAutoIdleBout();
    } else if (roll < 0.55) {
      _resetConsecutiveIdleReps();
      await playMotion(
        PetMotion.walk,
        fromAuto: true,
        repeatCount: 1 + _random.nextInt(2),
      );
    } else if (roll < 0.75) {
      _resetConsecutiveIdleReps();
      await playMotion(PetMotion.run, fromAuto: true, repeatCount: 1);
    } else {
      _resetConsecutiveIdleReps();
      await playMotion(PetMotion.sit, fromAuto: true);
    }
  }

  void _resetConsecutiveIdleReps() {
    _consecutiveIdleReps = 0;
  }

  /// walk/run/sit 등 non-idle 자동 ambient.
  /// non-idle 이 실제로 시작된 뒤에만 idle 카운터를 리셋한다.
  Future<void> _runNonIdleAutoBehavior() async {
    if (_manualControl || _assets == null || _eventMotionActive) {
      _scheduleAutoBehavior(delay: _randomIdleDelay());
      return;
    }
    final roll = _random.nextDouble();
    final genBefore = _motionGeneration;
    try {
      if (roll < 0.40) {
        await playMotion(
          PetMotion.walk,
          fromAuto: true,
          repeatCount: 1 + _random.nextInt(2),
        );
      } else if (roll < 0.70) {
        await playMotion(PetMotion.run, fromAuto: true, repeatCount: 1);
      } else {
        await playMotion(PetMotion.sit, fromAuto: true);
      }
      // playMotion 이 generation 을 올린 경우 = 실제 non-idle 진입.
      if (_motionGeneration != genBefore) {
        _resetConsecutiveIdleReps();
      } else if (isMounted && !_manualControl && !_eventMotionActive) {
        // early-return(예: sitting 중 walk 차단) 시 스케줄러가 죽지 않게.
        _scheduleAutoBehavior(delay: _randomIdleDelay());
      }
    } catch (e, st) {
      debugPrint(
        'AvoPetComponent non-idle ambient failed id=$userPetId: $e\n$st',
      );
      if (!isMounted || _manualControl || _eventMotionActive) return;
      _scheduleAutoBehavior(delay: _randomIdleDelay());
    }
  }

  /// idle 1회 발동: 최대 [kMaxConsecutiveIdleReps] cycle 한 세트 후 반드시 non-idle.
  /// bout 중간에 `_runAutoBehavior` 로 돌아가 idle 을 재뽑지 않는다.
  Future<void> _playAutoIdleBout() async {
    if (_manualControl || _assets == null || _eventMotionActive) {
      _scheduleAutoBehavior(delay: _randomIdleDelay());
      return;
    }

    final gen = _motionGeneration;
    _resetConsecutiveIdleReps();
    await _enterIdle(resetAuto: false, generation: gen);
    if (!isMounted || gen != _motionGeneration) {
      if (isMounted && !_manualControl && !_eventMotionActive) {
        _scheduleAutoBehavior(delay: _randomIdleDelay());
      }
      return;
    }
    await _runIdleBoutThenNonIdle(generation: gen);
  }

  double _idleVisualCycleDuration() {
    final base = _animationCycleDuration(_assets!.idleAnimation);
    // 화면 재생은 baseStepTime / speedMultiplier.
    return max(0.05, base / _speedMultiplier.clamp(0.25, 3.0));
  }

  /// 이미 idle 중인 1회 발동: cycle 을 세며(최대 8) 재생한 뒤 non-idle 로 넘긴다.
  Future<void> _runIdleBoutThenNonIdle({int? generation}) async {
    if (_manualControl || _assets == null || _eventMotionActive) {
      _scheduleAutoBehavior(delay: _randomIdleDelay());
      return;
    }
    final gen = generation ?? _motionGeneration;
    if (gen != _motionGeneration) {
      _scheduleAutoBehavior(delay: _randomIdleDelay());
      return;
    }

    final cycle = _idleVisualCycleDuration();
    // 기존 hold 길이와 비슷하되, 한 발동에서 최대 8 cycle 까지만.
    final desiredHold = _randomIdleDelay();
    var held = 0.0;

    while (_consecutiveIdleReps < kMaxConsecutiveIdleReps &&
        held < desiredHold &&
        isMounted &&
        gen == _motionGeneration &&
        _motion == PetMotion.idle &&
        !_manualControl &&
        !_eventMotionActive) {
      await _waitDuration(cycle, generation: gen);
      if (!isMounted || gen != _motionGeneration) {
        if (isMounted && !_manualControl && !_eventMotionActive) {
          _scheduleAutoBehavior(delay: _randomIdleDelay());
        }
        return;
      }
      if (_motion != PetMotion.idle || _manualControl || _eventMotionActive) {
        return;
      }
      _consecutiveIdleReps++;
      held += cycle;
    }

    if (!isMounted || gen != _motionGeneration) {
      if (isMounted && !_manualControl && !_eventMotionActive) {
        _scheduleAutoBehavior(delay: _randomIdleDelay());
      }
      return;
    }
    if (_manualControl || _eventMotionActive) return;

    // idle 1회 발동 종료 → 반드시 non-idle (idle 재선택 없음).
    await _runNonIdleAutoBehavior();
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
      // 이동 종료 후 등: 새 idle 1회 발동(최대 8 cycle) 후 non-idle.
      _resetConsecutiveIdleReps();
      unawaited(_runIdleBoutThenNonIdle(generation: generation));
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
  ///
  /// 스프라이트: 4프레임 loop (4→1 즉시). 전 사이클 동일.
  Future<void> _playDogPlayMoving({int? generation}) async {
    if (_assets == null) return;
    _isSitting = false;
    _dogPlaySameFacingCycles = 0;
    _dogPlayFacingLeft = null;
    _moveSpeed = kAvoPetRunSpeed;
    _moveTimeLeft = double.infinity;
    _pendingMoveCycleFinish = false;

    var remaining = max(1, _repeatRemaining);
    final loopAnim = _cloneAnimation(_assets!.playAnimation, loop: true);
    await _showAnimation(loopAnim);
    if (generation != null && generation != _motionGeneration) {
      _stopMovement();
      return;
    }

    while (remaining > 0 && isMounted) {
      if (generation != null && generation != _motionGeneration) {
        _stopMovement();
        return;
      }
      _beginDogPlayCycleMovement();
      await _waitForAnimation(loopAnim, generation: generation);
      remaining--;
    }

    _stopMovement();
    _dogPlaySameFacingCycles = 0;
    _dogPlayFacingLeft = null;
  }

  void _beginDogPlayCycleMovement() {
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
