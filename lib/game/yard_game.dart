import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:avopet/game/pet_collision_tune.dart';
import 'package:avopet/game/petting_heart_effect.dart';
import 'package:avopet/game/petting_heart_tune.dart';
import 'package:avopet/game/pet_motion.dart';
import 'package:avopet/game/pet_motion_tune.dart';
import 'package:avopet/game/pet_shadow_tune.dart';
import 'package:avopet/game/pet_sprite_assets.dart';
import 'package:avopet/game/avopet_component.dart';

/// Flame 마당 논리 캔버스 폭 (기존 Flutter 844×390 좌표계와 동일).
const double kYardGameWidth = 844;

/// Flame 마당 논리 캔버스 높이 (기존 Flutter 844×390 좌표계와 동일).
const double kYardGameHeight = 390;

/// 구름이 머물 수 있는 상단 하늘 영역 한계 (y=0~120, 상단 약 1/3).
const double kYardSkyBandMaxY = 120;

/// 구름 크기/위치/속도 튜닝 값.
///
/// - [CloudTuning.x], [CloudTuning.y], [CloudTuning.width], [CloudTuning.speed] 만
///   수정하면 된다.
/// - 수정 후 hot restart 로 빠르게 확인할 수 있다.
/// - 구름 y 는 2.5D 아이소메트릭 마당의 상단 하늘 영역 기준으로 0~120 안에서
///   조정한다.
class CloudTuning {
  const CloudTuning({
    required this.asset,
    required this.x,
    required this.y,
    required this.width,
    required this.speed,
  });

  final String asset;
  final double x;
  final double y;
  final double width;

  /// 가로 이동 속도(px/sec). 양수는 우측 이동.
  final double speed;
}

/// debug 튜닝 패널에서 실시간으로 변경하는 구름 런타임 설정.
class CloudRuntimeTuning {
  CloudRuntimeTuning({
    required this.asset,
    required this.x,
    required this.y,
    required this.width,
    required this.speed,
  });

  final String asset;
  double x;
  double y;
  double width;
  double speed;
}

/// 구름 초기 튜닝 값. x/y/width/speed 만 바꿔가며 조정한다.
const List<CloudTuning> kCloudTunings = [
  CloudTuning(
    asset: 'yard/cloud_01.png',
    x: -252.5,
    y: 0,
    width: 260,
    speed: 6,
  ),
  CloudTuning(
    asset: 'yard/cloud_02.png',
    x: -65.0,
    y: 34,
    width: 320,
    speed: 4,
  ),
  CloudTuning(
    asset: 'yard/cloud_03.png',
    x: 122.5,
    y: 0,
    width: 197.7,
    speed: 5,
  ),
  CloudTuning(
    asset: 'yard/cloud_04.png',
    x: 310.0,
    y: 0,
    width: 340,
    speed: 3.5,
  ),
  CloudTuning(
    asset: 'yard/cloud_05.png',
    x: 497.5,
    y: 10.9,
    width: 358.6,
    speed: 6,
  ),
  CloudTuning(
    asset: 'yard/cloud_06.png',
    x: 685.0,
    y: 17.6,
    width: 293.5,
    speed: 4,
  ),
  CloudTuning(
    asset: 'yard/cloud_07.png',
    x: 872.5,
    y: 10.6,
    width: 252.7,
    speed: 5,
  ),
  CloudTuning(
    asset: 'yard/cloud_08.png',
    x: -60.0,
    y: 11.4,
    width: 340,
    speed: 3.5,
  ),
];

/// collision_mask.png 제작 기준:
/// - 크기: 844 x 390 권장
/// - 배경: 투명
/// - 충돌영역: 빨간색으로 칠하기 (하늘·마당·오브젝트 등 모든 접근 불가 영역)
/// - 빨간색 영역은 alpha가 있어야 함
/// - 완전 투명 영역은 통과 가능
/// - 파일 위치: assets/images/yard/collision_mask.png
const String kCollisionMaskAssetPath = 'assets/images/yard/collision_mask.png';

/// collision mask alpha 판정 threshold (anti-aliasing 가장자리 보정).
const int kCollisionMaskAlphaThreshold = 32;

/// 굴뚝 연기 효과 튜닝 값.
///
/// - 844 x 390 논리 좌표 기준. [originX]/[originY] 가 굴뚝(연기 시작점)이다.
/// - 아주 약하고 느린 연기를 의도한다. 기본은 [spawnInterval] 마다
///   [puffsPerBurst] 개의 작은 puff 가 [riseDistance] 만큼 천천히 상승하며
///   [windDriftSpeed] 에 따라 우측으로 drift 하고 점점 투명해지고 커진다.
/// - 연기 효과는 debug/release 양쪽에서 모두 보인다(튜닝 UI 만 debug 전용).
class SmokeTuning {
  const SmokeTuning({
    required this.originX,
    required this.originY,
    required this.baseSize,
    required this.riseDistance,
    required this.duration,
    required this.spawnInterval,
    required this.puffsPerBurst,
    required this.opacity,
    required this.windDriftSpeed,
  });

  final double originX;
  final double originY;
  final double baseSize;
  final double riseDistance;
  final double duration;
  final double spawnInterval;
  final int puffsPerBurst;
  final double opacity;

  /// 바람에 의한 우측 drift 속도(px/sec). 양수는 우측 이동.
  final double windDriftSpeed;
}

/// debug 튜닝 패널에서 실시간으로 변경하는 굴뚝 연기 런타임 설정.
class SmokeRuntimeTuning {
  SmokeRuntimeTuning({
    required this.originX,
    required this.originY,
    required this.baseSize,
    required this.riseDistance,
    required this.duration,
    required this.spawnInterval,
    required this.puffsPerBurst,
    required this.opacity,
    required this.windDriftSpeed,
  });

  double originX;
  double originY;
  double baseSize;
  double riseDistance;
  double duration;
  double spawnInterval;
  int puffsPerBurst;
  double opacity;
  double windDriftSpeed;
}

/// 굴뚝 연기 초기값. 실제 굴뚝 위치는 debug 튜닝 패널로 조정한다(대략값).
const SmokeTuning kSmokeTuning = SmokeTuning(
  originX: 460.7,
  originY: 36.7,
  baseSize: 5.7,
  riseDistance: 51.4,
  duration: 3.4,
  spawnInterval: 1.7,
  puffsPerBurst: 4,
  opacity: 0.6,
  windDriftSpeed: 5,
);

/// AvoPet 2.5D 아이소메트릭 마당 Flame 게임 (1단계: 배경 + 구름).
///
/// 논리 좌표계는 기존 Flutter 마당과 동일한 [gameWidth] x [gameHeight]
/// (844 x 390)를 사용한다. [CameraComponent.withFixedResolution] 과
/// viewfinder 좌상단 정렬로 위젯 크기와 무관하게 844 x 390 전체가 보인다.
///
/// 레이어 우선순위:
///   0: sky_background (하늘 배경, 전체)
///   1: cloud_01~04 (상단 하늘 영역에서만 천천히 반복 이동)
///   2: yard_ground (오두막 포함, 하늘/구름 위에 배치)
///
/// 이번 단계에서는 펫 이동, 오두막 충돌, 굴뚝 연기, 잔디 흔들림을 구현하지 않는다.
/// 다만 이후 2.5D 아이소메트릭 이동/충돌을 추가할 수 있도록 구조를 분리해 둔다.
class YardGame extends FlameGame {
  YardGame()
    : super(
        camera: CameraComponent.withFixedResolution(
          width: kYardGameWidth,
          height: kYardGameHeight,
        ),
      );

  /// 기존 Flutter 마당 캔버스와 동일한 논리 좌표계 폭 (844).
  static const double gameWidth = kYardGameWidth;

  /// 기존 Flutter 마당 캔버스와 동일한 논리 좌표계 높이 (390).
  static const double gameHeight = kYardGameHeight;

  /// [gameWidth] 별칭 (기존 코드 호환).
  static const double logicalWidth = kYardGameWidth;

  /// [gameHeight] 별칭 (기존 코드 호환).
  static const double logicalHeight = kYardGameHeight;

  /// 구름이 머물 수 있는 상단 하늘 영역 한계.
  static const double skyBandMaxY = kYardSkyBandMaxY;

  final List<CloudRuntimeTuning> _cloudTunings = [];
  final List<_CloudComponent> _cloudComponents = [];

  ui.Image? _collisionMaskImage;
  ByteData? _collisionMaskBytes;
  int _collisionMaskWidth = 0;
  int _collisionMaskHeight = 0;
  bool _collisionMaskLoaded = false;
  SpriteComponent? _collisionMaskDebugOverlay;
  bool _collisionMaskDebugVisible = true;

  /// 마당에 표시 중인 모든 Flame 펫 (active + resident).
  final Map<String, AvoPetComponent> _petsById = {};

  AvoPetComponent? _avoPetComponent;
  String? _activePetUserId;
  String? _lastPetSpawnError;

  /// spawn/remove 경쟁 방지. remove 또는 새 spawn 요청 시 증가한다.
  int _petMutationEpoch = 0;
  Future<bool>? _petSpawnInFlight;
  String? _petSpawnInFlightUserId;

  bool _showPetCollisionDebug = true;
  _PetCollisionDebugComponent? _petCollisionDebug;

  final PetShadowTuneStore _petShadowTunes = PetShadowTuneStore();
  final PetCollisionTuneStore _petCollisionTunes = PetCollisionTuneStore();
  final PettingHeartTuneConfig _pettingHeartTune = PettingHeartTuneConfig();

  final Completer<void> _onLoadCompleter = Completer<void>();

  /// [onLoad] 완료를 외부에서 await 할 수 있는 Future.
  /// (FlameGame.ready() 메서드와 구분하기 위해 yardReady 로 명명)
  Future<void> get yardReady => _onLoadCompleter.future;

  /// 마지막 Flame 펫 spawn 실패 메시지 (debug 추적용).
  String? get lastPetSpawnError => _lastPetSpawnError;

  final SmokeRuntimeTuning _smokeTuning = SmokeRuntimeTuning(
    originX: kSmokeTuning.originX,
    originY: kSmokeTuning.originY,
    baseSize: kSmokeTuning.baseSize,
    riseDistance: kSmokeTuning.riseDistance,
    duration: kSmokeTuning.duration,
    spawnInterval: kSmokeTuning.spawnInterval,
    puffsPerBurst: kSmokeTuning.puffsPerBurst,
    opacity: kSmokeTuning.opacity,
    windDriftSpeed: kSmokeTuning.windDriftSpeed,
  );

  /// debug 튜닝 패널에서 읽기 전용으로 접근하는 구름 런타임 설정.
  List<CloudRuntimeTuning> get cloudTunings => List.unmodifiable(_cloudTunings);

  // ---------------------------------------------------------------------------
  // 펫 그림자 튜닝 (시각 효과 전용, 충돌/터치에 영향 없음). 종×단계별.
  // ---------------------------------------------------------------------------

  /// 종×단계 전체 그림자 튜닝 저장소.
  PetShadowTuneStore get petShadowTunes => _petShadowTunes;

  /// [speciesCode] + [stage] 에 해당하는 그림자 설정 (adult → teen).
  PetShadowTuneConfig petShadowTuneFor({
    required String speciesCode,
    required String stage,
  }) {
    return _petShadowTunes.forPet(speciesCode: speciesCode, stage: stage);
  }

  /// 저장된/패널에서 조정한 그림자 맵을 일괄 반영한다.
  void applyPetShadowTunes(PetShadowTuneStore store) {
    _petShadowTunes.applyAll(store);
    _petShadowTunes.clampAllScales();
  }

  /// 특정 종×단계 슬롯의 그림자 값을 즉시 반영한다.
  void updatePetShadowTune({
    required String speciesCode,
    required String stage,
    bool? enabled,
    Color? color,
    double? opacity,
    double? offsetX,
    double? offsetY,
    double? widthScale,
    double? heightScale,
    double? blurSigma,
  }) {
    final tune = _petShadowTunes.forPet(
      speciesCode: speciesCode,
      stage: stage,
    );
    if (enabled != null) tune.enabled = enabled;
    if (color != null) tune.color = color;
    if (opacity != null) tune.opacity = opacity;
    if (offsetX != null) tune.offsetX = offsetX;
    if (offsetY != null) tune.offsetY = offsetY;
    if (widthScale != null) {
      tune.widthScale = clampPetShadowWidthScale(widthScale);
    }
    if (heightScale != null) {
      tune.heightScale = clampPetShadowHeightScale(heightScale);
    }
    if (blurSigma != null) tune.blurSigma = blurSigma;
  }

  /// 특정 종×단계 슬롯을 기본값으로 복구한다.
  void resetPetShadowTune({
    required String speciesCode,
    required String stage,
  }) {
    _petShadowTunes.resetSlot(speciesCode: speciesCode, stage: stage);
  }

  /// 모든 종×단계 슬롯을 기본값으로 복구한다.
  void resetAllPetShadowTunes() {
    _petShadowTunes.resetAllToDefaults();
  }

  // ---------------------------------------------------------------------------
  // 펫 이동 collision footprint 튜닝. 종×단계별.
  // ---------------------------------------------------------------------------

  PetCollisionTuneStore get petCollisionTunes => _petCollisionTunes;

  PetCollisionTuneConfig petCollisionTuneFor({
    required String speciesCode,
    required String stage,
  }) {
    return _petCollisionTunes.forPet(speciesCode: speciesCode, stage: stage);
  }

  void applyPetCollisionTunes(PetCollisionTuneStore store) {
    _petCollisionTunes.applyAll(store);
  }

  void updatePetCollisionTune({
    required String speciesCode,
    required String stage,
    double? width,
    double? height,
    double? offsetX,
    double? offsetY,
  }) {
    final tune = _petCollisionTunes.forPet(
      speciesCode: speciesCode,
      stage: stage,
    );
    if (width != null) tune.width = width;
    if (height != null) tune.height = height;
    if (offsetX != null) tune.offsetX = offsetX;
    if (offsetY != null) tune.offsetY = offsetY;
  }

  void resetPetCollisionTune({
    required String speciesCode,
    required String stage,
  }) {
    _petCollisionTunes.resetSlot(speciesCode: speciesCode, stage: stage);
  }

  void resetAllPetCollisionTunes() {
    _petCollisionTunes.resetAllToDefaults();
  }

  // ---------------------------------------------------------------------------
  // 펫 모션 튜닝 (spd/rep). 종×단계×모션별.
  // ---------------------------------------------------------------------------

  final PetMotionTuneStore _petMotionTunes = PetMotionTuneStore();

  PetMotionTuneStore get petMotionTunes => _petMotionTunes;

  PetMotionTuneConfig petMotionTuneFor({
    required String speciesCode,
    required String stage,
    required PetMotion motion,
  }) {
    return _petMotionTunes.forPet(
      speciesCode: speciesCode,
      stage: stage,
      motion: motion,
    );
  }

  void applyPetMotionTunes(PetMotionTuneStore store) {
    _petMotionTunes.applyAll(store);
  }

  void updatePetMotionTune({
    required String speciesCode,
    required String stage,
    required PetMotion motion,
    double? speedMultiplier,
    int? repeatCount,
  }) {
    final tune = _petMotionTunes.forPet(
      speciesCode: speciesCode,
      stage: stage,
      motion: motion,
    );
    if (speedMultiplier != null) tune.speedMultiplier = speedMultiplier;
    if (repeatCount != null) tune.repeatCount = repeatCount;
  }

  void resetPetMotionTune({
    required String speciesCode,
    required String stage,
    required PetMotion motion,
  }) {
    _petMotionTunes.resetSlot(
      speciesCode: speciesCode,
      stage: stage,
      motion: motion,
    );
  }

  void resetPetMotionTunesForSpeciesStage({
    required String speciesCode,
    required String stage,
  }) {
    _petMotionTunes.resetSpeciesStage(
      speciesCode: speciesCode,
      stage: stage,
    );
  }

  // ---------------------------------------------------------------------------
  // 쓰다듬기 하트 이펙트 (시각 효과 전용, 충돌/터치에 영향 없음).
  // ---------------------------------------------------------------------------

  /// 현재 쓰다듬기 하트 튜닝 설정.
  PettingHeartTuneConfig get pettingHeartTune => _pettingHeartTune;

  void applyPettingHeartTune(PettingHeartTuneConfig config) {
    _pettingHeartTune.copyFrom(config);
  }

  void updatePettingHeartTune({
    bool? enabled,
    Color? color,
    double? opacity,
    double? size,
    double? offsetX,
    double? offsetY,
    double? riseDistance,
    int? durationMs,
    double? scaleStart,
    double? scaleEnd,
    int? burstIntervalMs,
  }) {
    if (enabled != null) _pettingHeartTune.enabled = enabled;
    if (color != null) _pettingHeartTune.color = color;
    if (opacity != null) _pettingHeartTune.opacity = opacity;
    if (size != null) _pettingHeartTune.size = size;
    if (offsetX != null) _pettingHeartTune.offsetX = offsetX;
    if (offsetY != null) _pettingHeartTune.offsetY = offsetY;
    if (riseDistance != null) _pettingHeartTune.riseDistance = riseDistance;
    if (durationMs != null) _pettingHeartTune.durationMs = durationMs;
    if (scaleStart != null) _pettingHeartTune.scaleStart = scaleStart;
    if (scaleEnd != null) _pettingHeartTune.scaleEnd = scaleEnd;
    if (burstIntervalMs != null) {
      _pettingHeartTune.burstIntervalMs = burstIntervalMs;
    }
  }

  void resetPettingHeartTune() {
    _pettingHeartTune.resetToDefaults();
  }

  /// 활성 펫 머리 위에서 쓰다듬기 하트 1개를 생성한다. 펫 없거나 비활성 시 no-op.
  /// [force] true 이면 debug Spawn Heart 등에서 enabled 무시.
  void spawnPettingHeart({bool force = false}) {
    if (!force && !_pettingHeartTune.enabled) return;
    final pet = _avoPetComponent;
    if (pet == null || !_isAvoPetAlive(pet)) return;

    final startX = pet.position.x + _pettingHeartTune.offsetX;
    final startY = pet.position.y - pet.size.y + _pettingHeartTune.offsetY;

    world.add(
      PettingHeartEffectComponent(
        tune: _pettingHeartTune,
        startPosition: Vector2(startX, startY),
      ),
    );
  }

  /// 하트를 [count]개, [burstIntervalMs] 간격으로 연속 생성한다.
  void spawnPettingHeartBurst({
    int count = kPettingHeartDefaultBurstCount,
    bool force = false,
  }) {
    if (!force && !_pettingHeartTune.enabled) return;
    if (!_isAvoPetAlive(_avoPetComponent)) return;

    final intervalMs = _pettingHeartTune.burstIntervalMs.clamp(0, 2000);
    for (var i = 0; i < count; i++) {
      final delay = Duration(milliseconds: intervalMs * i);
      Future<void>.delayed(delay, () {
        if (!_isAvoPetAlive(_avoPetComponent)) return;
        spawnPettingHeart(force: force);
      });
    }
  }

  // ---------------------------------------------------------------------------
  // collision mask API. 이동 충돌은 collision_mask.png 단일 소스로 처리한다.
  // ---------------------------------------------------------------------------

  /// collision_mask.png 가 로드되었는지 여부.
  bool get collisionMaskLoaded => _collisionMaskLoaded;

  /// [point] 가 collision mask 의 blocked 영역(alpha >= threshold) 안에 있는지 여부.
  ///
  /// mask 가 로드되지 않았으면 false (충돌 없음). 좌표는 844×390 논리 좌표 기준.
  bool isInsideCollisionMask(Vector2 point) {
    final bytes = _collisionMaskBytes;
    if (!_collisionMaskLoaded || bytes == null) return false;

    if (point.x < 0 ||
        point.y < 0 ||
        point.x > gameWidth ||
        point.y > gameHeight) {
      return true;
    }

    final px = (point.x / gameWidth * _collisionMaskWidth).floor().clamp(
      0,
      _collisionMaskWidth - 1,
    );
    final py = (point.y / gameHeight * _collisionMaskHeight).floor().clamp(
      0,
      _collisionMaskHeight - 1,
    );

    final index = (py * _collisionMaskWidth + px) * 4;
    if (index < 0 || index + 3 >= bytes.lengthInBytes) return false;

    final a = bytes.getUint8(index + 3);
    return a >= kCollisionMaskAlphaThreshold;
  }

  /// 아보펫 이동 가능 여부 (collision mask).
  bool canPetMoveTo(Vector2 current, Vector2 next) {
    final allowed = _computeCanPetMoveTo(current, next);
    if (!allowed && kDebugMode) {
      _logMoveBlocked(current, next);
    }
    return allowed;
  }

  bool _computeCanPetMoveTo(Vector2 current, Vector2 next) {
    return !isInsideCollisionMask(next);
  }

  /// footprint(발밑 sample point 목록) 기준 이동 가능 여부.
  ///
  /// 발밑 한 점이 아니라 footprint 전체를 검사한다.
  /// footprint 크기 자체는 [AvoPetComponent] 의 상수로 튜닝한다.
  /// [excludingPetId] 는 자기 자신 및 해당 펫과의 pet-to-pet 검사를 건너뛴다.
  bool canPetFootprintMoveTo(
    List<Vector2> currentPoints,
    List<Vector2> nextPoints, {
    String? excludingPetId,
  }) {
    final allowed = _computeCanPetFootprintMoveTo(
      currentPoints,
      nextPoints,
      excludingPetId: excludingPetId,
    );
    if (!allowed && kDebugMode) {
      _logFootprintBlocked(currentPoints, nextPoints);
    }
    return allowed;
  }

  bool _computeCanPetFootprintMoveTo(
    List<Vector2> currentPoints,
    List<Vector2> nextPoints, {
    String? excludingPetId,
  }) {
    final currentMaskBlockedCount = currentPoints
        .where(isInsideCollisionMask)
        .length;
    final nextMaskBlockedCount = nextPoints.where(isInsideCollisionMask).length;

    if (nextMaskBlockedCount > 0) {
      if (currentMaskBlockedCount > 0 &&
          nextMaskBlockedCount < currentMaskBlockedCount) {
        // mask 탈출은 허용하되, pet overlap 악화는 아래에서 추가 검사.
      } else {
        return false;
      }
    }

    return _computePetToPetFootprintAllowed(
      currentPoints,
      nextPoints,
      excludingPetId: excludingPetId,
    );
  }

  /// 다른 펫 footprint 와의 겹침 점수(sample point 가 상대 footprint 안인 개수).
  double _petOverlapScore(
    List<Vector2> points, {
    required String? excludingPetId,
  }) {
    var score = 0.0;
    for (final other in _petsById.values) {
      if (!_isAvoPetAlive(other)) continue;
      if (excludingPetId != null && other.userPetId == excludingPetId) {
        continue;
      }
      final rect = other.collisionFootprintRect;
      for (final p in points) {
        if (rect.contains(Offset(p.x, p.y))) {
          score += 1;
        }
      }
    }
    return score;
  }

  /// pet-to-pet: 평소 새 충돌은 즉시 차단.
  /// 이미 겹친 spawn 상태에서는 overlap 감소/유지 이동만 허용.
  bool _computePetToPetFootprintAllowed(
    List<Vector2> currentPoints,
    List<Vector2> nextPoints, {
    String? excludingPetId,
  }) {
    final currentScore = _petOverlapScore(
      currentPoints,
      excludingPetId: excludingPetId,
    );
    final nextScore = _petOverlapScore(
      nextPoints,
      excludingPetId: excludingPetId,
    );

    if (currentScore > 0) {
      return nextScore <= currentScore;
    }
    return nextScore <= 0;
  }

  double _lastBlockLogSeconds = 0;

  /// 이동이 막혔을 때만, 그리고 0.5초에 한 번만 debug 로그를 남긴다(과도한 로그 방지).
  void _logMoveBlocked(Vector2 current, Vector2 next) {
    final nowSeconds = DateTime.now().millisecondsSinceEpoch / 1000.0;
    if (nowSeconds - _lastBlockLogSeconds < 0.5) return;
    _lastBlockLogSeconds = nowSeconds;
    debugPrint(
      'Pet move blocked: current=$current next=$next '
      'insideMask=${isInsideCollisionMask(next)}',
    );
  }

  /// footprint 이동이 막혔을 때만, 0.5초 throttle 로 debug 로그를 남긴다.
  void _logFootprintBlocked(
    List<Vector2> currentPoints,
    List<Vector2> nextPoints,
  ) {
    final nowSeconds = DateTime.now().millisecondsSinceEpoch / 1000.0;
    if (nowSeconds - _lastBlockLogSeconds < 0.5) return;
    _lastBlockLogSeconds = nowSeconds;
    final current = currentPoints.isNotEmpty
        ? currentPoints.first
        : Vector2.zero();
    final next = nextPoints.isNotEmpty ? nextPoints.first : Vector2.zero();
    debugPrint(
      'Pet footprint move blocked: current=$current next=$next '
      'nextInsideMask=${nextPoints.any(isInsideCollisionMask)}',
    );
  }

  bool _isAvoPetAlive(AvoPetComponent? pet) {
    if (pet == null) return false;
    return pet.isMounted || pet.parent != null;
  }

  bool get hasActiveAvoPet => _isAvoPetAlive(_avoPetComponent);

  // ---------------------------------------------------------------------------
  // 활성 Flame 펫 tap hitbox 판정 API.
  //
  // GameWidget 은 IgnorePointer 로 감싸져 있어 Flame 이 직접 pointer event 를
  // 받지 않는다. 대신 Flutter overlay 의 GestureDetector 가 tapDown 위치를 받아
  // 이 API 로 현재 움직이는 펫의 위치와 비교한다.
  // ---------------------------------------------------------------------------

  /// 현재 활성 펫의 tap hitbox(844×390 논리 좌표계). 펫이 없거나 mount 전이면 null.
  ///
  /// [AvoPetComponent] 는 anchor=bottomCenter 라 position 은 펫 발밑 중앙이다.
  /// 실제 sprite 보다 약간 넉넉하게(가로 1.3배, 세로 1.25배) 잡아 클릭을 쉽게 하되,
  /// 빈 공간이 과하게 반응하지 않도록 한다. size 기반이라 성숙기 크기 확장도 따라간다.
  Rect? get activePetHitboxRect {
    final pet = _avoPetComponent;
    if (pet == null || !_isAvoPetAlive(pet)) return null;

    final pos = pet.position;
    final size = pet.size;
    final width = size.x * 1.3;
    final height = size.y * 1.25;
    return Rect.fromLTWH(
      pos.x - width / 2,
      pos.y - size.y * 1.125,
      width,
      height,
    );
  }

  /// Flutter overlay 의 tap 위치([point], GameWidget 과 동일 영역의 widget-local
  /// Offset)가 현재 펫 hitbox 안에 있는지 판정한다.
  bool isPointInsideActivePetHitbox(Offset point) {
    final rect = activePetHitboxRect;
    if (rect == null) return false;
    final logical = widgetPointToLogical(point);
    if (logical == null) return false;
    return rect.contains(Offset(logical.x, logical.y));
  }

  /// widget-local 픽셀 좌표([point], GameWidget 렌더 박스 기준)를 844×390 논리
  /// 좌표로 변환한다.
  ///
  /// [CameraComponent.globalToLocal] 이 FixedResolution viewport 의 letterbox 와
  /// viewfinder 변환을 모두 처리한다. 아직 mount 전이거나 변환 불가 시 null.
  Vector2? widgetPointToLogical(Offset point) {
    if (!isMounted) return null;
    try {
      return camera.globalToLocal(Vector2(point.dx, point.dy));
    } catch (e) {
      debugPrint('YardGame.widgetPointToLogical failed: $e');
      return null;
    }
  }

  Future<void> _ensureGameLoaded() async {
    if (!_onLoadCompleter.isCompleted) {
      debugPrint('YardGame: waiting for onLoad before pet spawn');
      await _onLoadCompleter.future;
    }
  }

  Future<bool> _spawnYardPetComponent({
    required String userPetId,
    required String speciesCode,
    required String stage,
    bool isDebugOnly = false,
    bool isResident = false,
    Vector2? position,
    bool? seedRandomAmbient,
  }) async {
    final epoch = ++_petMutationEpoch;
    final seedAmbient = seedRandomAmbient ?? (position == null);

    if (isResident) {
      await _removePetById(userPetId, bumpEpoch: false);
    } else {
      // 이전 active 가 다른 펫이면 제거하지 않고 resident 로 강등(위치 유지).
      final previous = _avoPetComponent;
      if (previous != null &&
          previous.userPetId != userPetId &&
          _isAvoPetAlive(previous)) {
        previous.isResident = true;
        _avoPetComponent = null;
        _activePetUserId = null;
      } else {
        await removeActivePetComponent(bumpEpoch: false);
      }
      await _removePetById(userPetId, bumpEpoch: false);
    }

    if (epoch != _petMutationEpoch) {
      debugPrint('YardGame: spawn aborted before add (stale epoch)');
      return false;
    }

    final component = AvoPetComponent(
      userPetId: userPetId,
      speciesCode: speciesCode,
      stage: stage,
      isDebugOnly: isDebugOnly,
      isResident: isResident,
      initialPosition: position,
      seedRandomAmbient: seedAmbient,
      canMoveFootprintTo: (current, next) => canPetFootprintMoveTo(
        current,
        next,
        excludingPetId: userPetId,
      ),
    );
    _petsById[userPetId] = component;
    if (!isResident) {
      _avoPetComponent = component;
      _activePetUserId = userPetId;
    }

    await world.add(component);
    await Future<void>.delayed(Duration.zero);

    if (epoch != _petMutationEpoch) {
      debugPrint('YardGame: spawn stale after add — removing orphan component');
      component.removeFromParent();
      if (identical(_petsById[userPetId], component)) {
        _petsById.remove(userPetId);
      }
      if (identical(_avoPetComponent, component)) {
        _avoPetComponent = null;
        _activePetUserId = null;
      }
      return false;
    }

    final alive = _isAvoPetAlive(component);
    if (!alive) {
      _lastPetSpawnError =
          'AvoPetComponent was not mounted after world.add (mounted=${component.isMounted}, parent=${component.parent != null})';
      debugPrint('YardGame: $_lastPetSpawnError');
      _petsById.remove(userPetId);
      if (identical(_avoPetComponent, component)) {
        _avoPetComponent = null;
        _activePetUserId = null;
      }
      return false;
    }

    debugPrint(
      'YardGame: pet spawned id=$userPetId species=$speciesCode stage=$stage '
      'resident=$isResident mounted=${component.isMounted}',
    );
    return true;
  }

  /// 종·단계 지정 Flame 펫을 마당에 표시한다 (active).
  ///
  /// [seedRandomAmbient] 를 false 로 주면 랜덤 배치 없이 기본 스폰 위치
  /// (오두막 문 앞)를 사용한다. 신규 분양이 여기에 해당한다.
  Future<bool> showYardPet({
    required String userPetId,
    required String speciesCode,
    required String stage,
    Vector2? position,
    bool? seedRandomAmbient,
  }) async {
    if (_petSpawnInFlight != null && _petSpawnInFlightUserId == userPetId) {
      debugPrint(
        'YardGame: showYardPet join in-flight spawn (userPetId=$userPetId)',
      );
      return _petSpawnInFlight!;
    }

    final future = _showYardPetImpl(
      userPetId: userPetId,
      speciesCode: speciesCode,
      stage: stage,
      position: position,
      seedRandomAmbient: seedRandomAmbient,
    );
    _petSpawnInFlight = future;
    _petSpawnInFlightUserId = userPetId;
    try {
      return await future;
    } finally {
      if (identical(_petSpawnInFlight, future)) {
        _petSpawnInFlight = null;
        _petSpawnInFlightUserId = null;
      }
    }
  }

  Future<bool> _showYardPetImpl({
    required String userPetId,
    required String speciesCode,
    required String stage,
    Vector2? position,
    bool? seedRandomAmbient,
  }) async {
    try {
      _lastPetSpawnError = null;
      await _ensureGameLoaded();

      final existing = _petsById[userPetId];
      if (existing != null &&
          _isAvoPetAlive(existing) &&
          existing.speciesCode == speciesCode) {
        // 동일 펫: 단계만 바뀌면 제자리 교체 (사라졌다 나타나기 방지).
        if (existing.stage != stage ||
            petStageAssetFolder(existing.stage) !=
                petStageAssetFolder(stage)) {
          await existing.applyStageInPlace(stage);
        }
        // 다른 active 가 있으면 resident 로 강등.
        final previous = _avoPetComponent;
        if (previous != null &&
            previous.userPetId != userPetId &&
            _isAvoPetAlive(previous)) {
          previous.isResident = true;
        }
        existing.isResident = false;
        _avoPetComponent = existing;
        _activePetUserId = userPetId;
        debugPrint(
          'YardGame: yard pet in-place update (userPetId=$userPetId stage=$stage)',
        );
        return true;
      }

      // 다른 펫으로 active 교체 시에는 이전 펫 위치를 물려받지 않는다.
      // (같은 userPetId 재스폰/단계 변경만 위치 유지)
      Vector2? spawnPosition = position;
      var seedAmbient = seedRandomAmbient ?? (position == null);
      if (spawnPosition == null &&
          existing != null &&
          _isAvoPetAlive(existing)) {
        spawnPosition = existing.position.clone();
        seedAmbient = false;
      }

      return await _spawnYardPetComponent(
        userPetId: userPetId,
        speciesCode: speciesCode,
        stage: stage,
        position: spawnPosition,
        seedRandomAmbient: seedAmbient,
      );
    } catch (e, st) {
      _lastPetSpawnError = e.toString();
      debugPrint('YardGame.showYardPet failed: $e\n$st');
      _petsById.remove(userPetId);
      if (_activePetUserId == userPetId) {
        _avoPetComponent = null;
        _activePetUserId = null;
      }
      return false;
    }
  }

  /// 하위 호환: cat_sco baby active spawn.
  Future<bool> showCatScoBabyPet({required String userPetId}) {
    return showYardPet(
      userPetId: userPetId,
      speciesCode: 'cat_sco',
      stage: 'baby',
    );
  }

  /// resident 펫 목록을 Flame 마당과 동기화한다 (active 제외).
  /// 기존 마당 펫 위치는 유지한다 (격자 재배치/순간이동 없음).
  Future<void> syncResidentYardPets(
    List<({String userPetId, String speciesCode, String stage})> pets,
  ) async {
    await _ensureGameLoaded();
    final desiredIds = pets.map((p) => p.userPetId).toSet();

    for (final entry in _petsById.entries.toList()) {
      final pet = entry.value;
      if (!pet.isResident) continue;
      if (!desiredIds.contains(entry.key)) {
        pet.removeFromParent();
        _petsById.remove(entry.key);
      }
    }

    for (final spec in pets) {
      if (_activePetUserId == spec.userPetId) {
        continue;
      }
      final existing = _petsById[spec.userPetId];
      if (existing != null &&
          _isAvoPetAlive(existing) &&
          existing.speciesCode == spec.speciesCode) {
        if (existing.stage != spec.stage ||
            petStageAssetFolder(existing.stage) !=
                petStageAssetFolder(spec.stage)) {
          await existing.applyStageInPlace(spec.stage);
        }
        existing.isResident = true;
        if (identical(_avoPetComponent, existing)) {
          _avoPetComponent = null;
          _activePetUserId = null;
        }
        continue;
      }

      // 마당에 없던 resident: 위치 보존 재스폰은 유지, 신규(앱 재시작 등)는 랜덤 시드.
      final preserved = (existing != null && _isAvoPetAlive(existing))
          ? existing.position.clone()
          : null;
      await _spawnYardPetComponent(
        userPetId: spec.userPetId,
        speciesCode: spec.speciesCode,
        stage: spec.stage,
        isResident: true,
        position: preserved,
        seedRandomAmbient: preserved == null,
      );
    }
  }

  /// debug 전용: DB 변경 없이 cat_sco baby 를 스폰한다.
  Future<bool> showCatScoBabyPetDebug() async {
    const debugId = 'debug-cat-sco-baby';
    if (_petSpawnInFlight != null && _petSpawnInFlightUserId == debugId) {
      return _petSpawnInFlight!;
    }

    final future = _showYardPetDebugImpl(
      userPetId: debugId,
      speciesCode: 'cat_sco',
      stage: 'baby',
    );
    _petSpawnInFlight = future;
    _petSpawnInFlightUserId = debugId;
    try {
      return await future;
    } finally {
      if (identical(_petSpawnInFlight, future)) {
        _petSpawnInFlight = null;
        _petSpawnInFlightUserId = null;
      }
    }
  }

  Future<bool> _showYardPetDebugImpl({
    required String userPetId,
    required String speciesCode,
    required String stage,
  }) async {
    try {
      _lastPetSpawnError = null;
      await _ensureGameLoaded();

      if (_avoPetComponent != null &&
          _activePetUserId == userPetId &&
          _isAvoPetAlive(_avoPetComponent)) {
        debugPrint('YardGame: debug pet already shown');
        return true;
      }

      final ok = await _spawnYardPetComponent(
        userPetId: userPetId,
        speciesCode: speciesCode,
        stage: stage,
        isDebugOnly: true,
      );
      if (ok) {
        debugPrint('YardGame: debug pet spawned ($speciesCode/$stage)');
      } else {
        debugPrint(
          'YardGame: debug pet spawn failed, error=$_lastPetSpawnError',
        );
      }
      return ok;
    } catch (e, st) {
      _lastPetSpawnError = e.toString();
      debugPrint('YardGame debug spawn failed: $e\n$st');
      _petsById.remove(userPetId);
      if (_activePetUserId == userPetId) {
        _avoPetComponent = null;
        _activePetUserId = null;
      }
      return false;
    }
  }

  Future<void> _removePetById(String? userPetId, {bool bumpEpoch = true}) async {
    if (userPetId == null) return;
    if (bumpEpoch) {
      _petMutationEpoch++;
    }
    final pet = _petsById.remove(userPetId);
    pet?.removeFromParent();
    if (_activePetUserId == userPetId) {
      _avoPetComponent = null;
      _activePetUserId = null;
    }
  }

  /// 활성 Flame 펫 컴포넌트를 제거한다 (resident 유지).
  Future<void> removeActivePetComponent({bool bumpEpoch = true}) async {
    if (bumpEpoch) {
      _petMutationEpoch++;
    }
    final activeId = _activePetUserId;
    if (activeId != null) {
      final pet = _petsById.remove(activeId);
      pet?.removeFromParent();
    } else {
      _avoPetComponent?.removeFromParent();
    }
    _avoPetComponent = null;
    _activePetUserId = null;
    _lastPetSpawnError = null;
  }

  /// 마당의 모든 Flame 펫을 제거한다.
  Future<void> removeAllPetComponents({bool bumpEpoch = true}) async {
    if (bumpEpoch) {
      _petMutationEpoch++;
    }
    for (final pet in _petsById.values.toList()) {
      pet.removeFromParent();
    }
    _petsById.clear();
    _avoPetComponent = null;
    _activePetUserId = null;
    _lastPetSpawnError = null;
  }

  /// 활성 펫에 모션을 발동한다. 펫이 없으면 no-op.
  void playPetMotion(
    PetMotion motion, {
    double? speedMultiplier,
    int? repeatCount,
  }) {
    final pet = _avoPetComponent;
    if (pet == null || !_isAvoPetAlive(pet)) return;
    unawaited(
      pet.playMotion(
        motion,
        speedMultiplier: speedMultiplier,
        repeatCount: repeatCount,
      ),
    );
  }

  /// debug 방향키: 활성 펫을 [direction] 방향으로 run 수동 이동시킨다. 펫 없으면 no-op.
  void startPetManualRunDirection(
    Vector2 direction, {
    double speedMultiplier = 1.0,
  }) {
    final pet = _avoPetComponent;
    if (pet == null || !_isAvoPetAlive(pet)) return;
    pet.startManualRun(direction, speedMultiplier: speedMultiplier);
  }

  /// debug 방향키: 수동 run 이동을 멈춘다. 펫 없으면 no-op.
  void stopPetManualRunDirection() {
    final pet = _avoPetComponent;
    if (pet == null || !_isAvoPetAlive(pet)) return;
    pet.stopManualRun();
  }

  /// 활성 펫의 발밑 충돌 footprint 사각형(844×390 논리 좌표). 펫 없으면 null.
  Rect? get activePetCollisionFootprintRect {
    final pet = _avoPetComponent;
    if (pet == null || !_isAvoPetAlive(pet)) return null;
    return pet.collisionFootprintRect;
  }

  /// 마당의 모든 펫 collision footprint (debug overlay 용).
  List<Rect> get allPetCollisionFootprintRects {
    return _petsById.values
        .where(_isAvoPetAlive)
        .map((p) => p.collisionFootprintRect)
        .toList();
  }

  /// debug 전용: active pet 이동 collision footprint overlay 표시 여부. release 무시.
  bool get petCollisionDebugVisible => _showPetCollisionDebug;

  /// debug 전용: collision mask overlay 표시 여부. release 에서는 표시되지 않는다.
  bool get collisionMaskDebugVisible => _collisionMaskDebugVisible;

  /// debug 전용: 이동 collision footprint overlay 표시를 토글한다. release 무시.
  void setActivePetCollisionDebugVisible(bool visible) {
    if (!kDebugMode) return;
    _showPetCollisionDebug = visible;
    _petCollisionDebug?.visibleOverride = visible;
  }

  /// debug 전용: collision mask overlay 표시를 토글한다. release 무시.
  void setCollisionMaskDebugVisible(bool visible) {
    if (!kDebugMode) return;
    _collisionMaskDebugVisible = visible;
    _refreshCollisionMaskDebugOverlay();
  }

  /// collision_mask.png 를 다시 로드한다. debug 튜닝 패널 Reload 용.
  ///
  /// 웹에서는 브라우저 캐시 때문에 완전 실시간 반영이 안 될 수 있다.
  /// 실패 시 hot restart 를 시도하라.
  Future<void> reloadCollisionMask() async {
    _collisionMaskDebugOverlay?.removeFromParent();
    _collisionMaskDebugOverlay = null;
    _collisionMaskImage?.dispose();
    _collisionMaskImage = null;
    _collisionMaskBytes = null;
    _collisionMaskWidth = 0;
    _collisionMaskHeight = 0;
    _collisionMaskLoaded = false;

    await _loadCollisionMask();
    if (kDebugMode) {
      _refreshCollisionMaskDebugOverlay();
    }
  }

  Future<void> _loadCollisionMask() async {
    try {
      final data = await rootBundle.load(kCollisionMaskAssetPath);
      final bytes = data.buffer.asUint8List();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );

      if (byteData == null) {
        debugPrint('YardGame collision mask: byteData is null');
        return;
      }

      _collisionMaskImage = image;
      _collisionMaskBytes = byteData;
      _collisionMaskWidth = image.width;
      _collisionMaskHeight = image.height;
      _collisionMaskLoaded = true;

      debugPrint(
        'YardGame collision mask loaded: ${image.width}x${image.height}',
      );
    } catch (e, st) {
      debugPrint('YardGame collision mask load skipped/failed: $e\n$st');
      _collisionMaskLoaded = false;
    }
  }

  /// debug 전용 collision mask overlay 를 최신 표시 상태로 다시 만든다.
  Future<void> _refreshCollisionMaskDebugOverlay() async {
    if (!kDebugMode) return;
    _collisionMaskDebugOverlay?.removeFromParent();
    _collisionMaskDebugOverlay = null;
    if (!_collisionMaskDebugVisible || !_collisionMaskLoaded) return;

    try {
      final sprite = await loadSprite('yard/collision_mask.png');
      final overlay = SpriteComponent(
        sprite: sprite,
        position: Vector2.zero(),
        size: Vector2(gameWidth, gameHeight),
        anchor: Anchor.topLeft,
        priority: 7,
      )..opacity = 0.35;
      _collisionMaskDebugOverlay = overlay;
      world.add(overlay);
    } catch (e, st) {
      debugPrint('YardGame collision mask debug overlay failed: $e\n$st');
    }
  }

  // ---------------------------------------------------------------------------
  // 굴뚝 연기 API (2단계). 연기 효과 자체는 release 에서도 표시된다.
  // ---------------------------------------------------------------------------

  /// debug 튜닝 패널에서 접근하는 굴뚝 연기 런타임 설정.
  SmokeRuntimeTuning get smokeTuning => _smokeTuning;

  /// 굴뚝 연기 값을 즉시 반영한다(이후 생성되는 puff 부터 반영, origin 은 즉시).
  void updateSmokeTuning({
    double? originX,
    double? originY,
    double? baseSize,
    double? riseDistance,
    double? duration,
    double? spawnInterval,
    int? puffsPerBurst,
    double? opacity,
    double? windDriftSpeed,
  }) {
    if (originX != null) _smokeTuning.originX = originX;
    if (originY != null) _smokeTuning.originY = originY;
    if (baseSize != null) _smokeTuning.baseSize = baseSize;
    if (riseDistance != null) _smokeTuning.riseDistance = riseDistance;
    if (duration != null) _smokeTuning.duration = duration;
    if (spawnInterval != null) _smokeTuning.spawnInterval = spawnInterval;
    if (puffsPerBurst != null) _smokeTuning.puffsPerBurst = puffsPerBurst;
    if (opacity != null) _smokeTuning.opacity = opacity;
    if (windDriftSpeed != null) _smokeTuning.windDriftSpeed = windDriftSpeed;
  }

  /// 현재 연기 값을 [kSmokeTuning] const 코드 형태로 반환한다.
  String buildSmokeTuningDebugText() {
    final t = _smokeTuning;
    final buffer = StringBuffer(
      'const SmokeTuning kSmokeTuning = SmokeTuning(\n',
    );
    buffer.writeln('  originX: ${_formatTuningNumber(t.originX)},');
    buffer.writeln('  originY: ${_formatTuningNumber(t.originY)},');
    buffer.writeln('  baseSize: ${_formatTuningNumber(t.baseSize)},');
    buffer.writeln('  riseDistance: ${_formatTuningNumber(t.riseDistance)},');
    buffer.writeln('  duration: ${_formatTuningNumber(t.duration)},');
    buffer.writeln('  spawnInterval: ${_formatTuningNumber(t.spawnInterval)},');
    buffer.writeln('  puffsPerBurst: ${t.puffsPerBurst},');
    buffer.writeln('  opacity: ${_formatTuningNumber(t.opacity)},');
    buffer.writeln(
      '  windDriftSpeed: ${_formatTuningNumber(t.windDriftSpeed)},',
    );
    buffer.write(');');
    return buffer.toString();
  }

  /// 구름 튜닝 값을 즉시 반영한다. [index] 는 0~7 (cloud_01~08).
  void updateCloudTuning(
    int index, {
    double? x,
    double? y,
    double? width,
    double? speed,
  }) {
    if (index < 0 || index >= _cloudTunings.length) return;
    final tuning = _cloudTunings[index];
    if (x != null) tuning.x = x;
    if (y != null) tuning.y = y;
    if (width != null) tuning.width = width;
    if (speed != null) tuning.speed = speed;
    if (index < _cloudComponents.length) {
      _cloudComponents[index].syncFromTuning();
    }
  }

  /// 현재 구름 튜닝 값을 [kCloudTunings] const 리스트 형태의 Dart 코드로 반환한다.
  String buildCloudTuningDebugText() {
    final buffer = StringBuffer('const List<CloudTuning> kCloudTunings = [\n');
    for (final tuning in _cloudTunings) {
      buffer.writeln('  CloudTuning(');
      buffer.writeln("    asset: '${tuning.asset}',");
      buffer.writeln('    x: ${_formatTuningNumber(tuning.x)},');
      buffer.writeln('    y: ${_formatTuningNumber(tuning.y)},');
      buffer.writeln('    width: ${_formatTuningNumber(tuning.width)},');
      buffer.writeln('    speed: ${_formatTuningNumber(tuning.speed)},');
      buffer.writeln('  ),');
    }
    buffer.write('];');
    return buffer.toString();
  }

  static String _formatTuningNumber(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(1);
  }

  // ---------------------------------------------------------------------------
  // 이동 충돌: collision_mask.png 단일 소스 (하늘·마당·오두막·오브젝트 포함).
  // ---------------------------------------------------------------------------

  @override
  Color backgroundColor() => const Color(0xFFDAF3DD);

  @override
  Future<void> onLoad() async {
    try {
      await super.onLoad();

      // yard / pets asset 모두 assets/images/ 하위에 있다.
      images.prefix = 'assets/images/';

      // 844×390 논리 좌표계: 좌상단 (0,0) 기준으로 전체 캔버스가 보이도록 카메라 정렬.
      // viewfinder 기본 anchor(center) 상태에서는 (0,0) 배치 스프라이트가 화면 밖으로
      // 밀려 검은 영역이 생길 수 있다.
      camera.viewfinder.anchor = Anchor.topLeft;
      camera.viewfinder.position = Vector2.zero();

      final skySprite = await loadSprite('yard/sky_background.png');
      final groundSprite = await loadSprite('yard/yard_ground.png');

      // 0) 하늘 배경: 844 x 390 전체를 빈틈없이 덮는다.
      _addFullCanvasSprite(skySprite, priority: 0);

      // 1) 구름 4개: sky_background 위, yard_ground 아래. 상단 하늘 영역(y=0~120)만.
      _cloudTunings
        ..clear()
        ..addAll(
          kCloudTunings.map(
            (tuning) => CloudRuntimeTuning(
              asset: tuning.asset,
              x: tuning.x,
              y: tuning.y,
              width: tuning.width,
              speed: tuning.speed,
            ),
          ),
        );
      _cloudComponents.clear();
      for (final tuning in _cloudTunings) {
        final cloudSprite = await loadSprite(tuning.asset);
        final component = _CloudComponent(tuning: tuning, sprite: cloudSprite);
        _cloudComponents.add(component);
        world.add(component);
      }

      // 2) 마당 지면(오두막 포함): 하늘/구름 위에 844 x 390 전체로 배치.
      _addFullCanvasSprite(groundSprite, priority: 2);

      // collision_mask.png: release/debug 모두 이동 collision 에 사용.
      await _loadCollisionMask();

      // 3) 굴뚝 연기: yard_ground(priority 2) 위에 표시. release 에서도 보인다.
      world.add(_SmokeEmitterComponent(tuning: _smokeTuning));

      // 4) debug overlay: collision mask + 이동 footprint (debug 빌드에서만).
      if (kDebugMode) {
        await _refreshCollisionMaskDebugOverlay();

        // 이동 collision footprint debug overlay (노란색): debug 빌드에서만
        //    추가한다. release 에서는 트리에 들어가지 않아 절대 보이지 않는다.
        //    펫 이동에 따라 매 프레임 갱신된다. (쓰다듬기 hitbox 와는 별개)
        final collisionDebug = _PetCollisionDebugComponent(game: this)
          ..visibleOverride = _showPetCollisionDebug;
        _petCollisionDebug = collisionDebug;
        world.add(collisionDebug);
      }
    } catch (e, st) {
      debugPrint('YardGame.onLoad failed: $e\n$st');
    } finally {
      if (!_onLoadCompleter.isCompleted) {
        _onLoadCompleter.complete();
      }
    }
  }

  /// 844×390 논리 캔버스 전체를 덮는 스프라이트를 좌상단 기준으로 배치한다.
  void _addFullCanvasSprite(Sprite sprite, {required int priority}) {
    world.add(
      SpriteComponent(
        sprite: sprite,
        position: Vector2.zero(),
        size: Vector2(gameWidth, gameHeight),
        anchor: Anchor.topLeft,
        priority: priority,
      ),
    );
  }
}

/// 상단 하늘 영역에서 가로로 천천히 반복 이동하는 구름 컴포넌트.
///
/// 화면 밖으로 완전히 나가면 반대편에서 다시 등장한다. y 좌표는 고정되어
/// 마당 중앙/하단으로 내려오지 않는다.
class _CloudComponent extends SpriteComponent {
  _CloudComponent({required CloudRuntimeTuning tuning, required Sprite sprite})
    : _tuning = tuning,
      super(
        sprite: sprite,
        priority: 1,
        position: Vector2(tuning.x, tuning.y),
        size: _sizeFromWidth(sprite, tuning.width),
        anchor: Anchor.topLeft,
      );

  final CloudRuntimeTuning _tuning;

  /// [CloudRuntimeTuning] 의 현재 값을 position/size 에 즉시 반영한다.
  void syncFromTuning() {
    position.x = _tuning.x;
    position.y = _tuning.y;
    size = _sizeFromWidth(sprite!, _tuning.width);
  }

  /// [width] 기준으로 원본 종횡비를 유지한 크기를 계산한다.
  static Vector2 _sizeFromWidth(Sprite sprite, double width) {
    final srcSize = sprite.srcSize;
    final aspect = srcSize.x <= 0 || srcSize.y <= 0
        ? 1.0
        : srcSize.x / srcSize.y;
    return Vector2(width, width / aspect);
  }

  @override
  void update(double dt) {
    super.update(dt);
    final speed = _tuning.speed;
    position.x += speed * dt;

    final cloudWidth = size.x;
    if (speed >= 0) {
      // 우측으로 완전히 빠져나가면 좌측 밖에서 다시 등장.
      if (position.x > YardGame.gameWidth) {
        position.x = -cloudWidth;
      }
    } else {
      // 좌측으로 완전히 빠져나가면 우측 밖에서 다시 등장.
      if (position.x + cloudWidth < 0) {
        position.x = YardGame.gameWidth;
      }
    }
  }
}

/// 마당 펫들의 이동 collision footprint 를 시각화하는 debug 전용 반투명 사각형.
///
/// debug 빌드에서만 world 에 추가되며 release 에서는 절대 생성되지 않는다.
class _PetCollisionDebugComponent extends Component {
  _PetCollisionDebugComponent({required YardGame game})
    : _game = game,
      super(priority: 750);

  final YardGame _game;
  bool visibleOverride = true;

  final Paint _fillPaint = Paint()..color = const Color(0x55FFEB3B);
  final Paint _strokePaint = Paint()
    ..color = const Color(0xCCFFC107)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;

  List<Rect> _rects = const [];

  @override
  void update(double dt) {
    super.update(dt);
    _rects = visibleOverride
        ? _game.allPetCollisionFootprintRects
        : const [];
  }

  @override
  void render(Canvas canvas) {
    for (final rect in _rects) {
      canvas.drawRect(rect, _fillPaint);
      canvas.drawRect(rect, _strokePaint);
    }
  }
}

/// 굴뚝 연기 이미터. [spawnInterval] 마다 [puffsPerBurst] 개의 puff 를 생성한다.
///
/// 렌더링이 없는 로직 전용 컴포넌트이며, 생성한 puff 들은 world 에 추가된다.
/// 튜닝 값은 매 spawn 시점에 다시 읽으므로 origin/interval/개수 변경이 즉시,
/// 그리고 baseSize/riseDistance/duration/opacity 는 이후 생성되는 puff 부터
/// 반영된다.
class _SmokeEmitterComponent extends Component {
  _SmokeEmitterComponent({required SmokeRuntimeTuning tuning})
    : _tuning = tuning;

  final SmokeRuntimeTuning _tuning;
  final Random _random = Random();
  double _timer = 0;

  @override
  void update(double dt) {
    super.update(dt);
    _timer += dt;
    final interval = _tuning.spawnInterval <= 0 ? 0.5 : _tuning.spawnInterval;
    if (_timer >= interval) {
      _timer = 0;
      _spawnBurst();
    }
  }

  void _spawnBurst() {
    final parentComponent = parent;
    if (parentComponent == null) return;
    final count = _tuning.puffsPerBurst.clamp(1, 8);
    for (var i = 0; i < count; i++) {
      // 굴뚝 입구 부근의 작은 random offset.
      final startX = _tuning.originX + (_random.nextDouble() - 0.5) * 6;
      final startY = _tuning.originY + (_random.nextDouble() - 0.5) * 4;
      parentComponent.add(
        _SmokePuffComponent(
          startX: startX,
          startY: startY,
          baseSize: _tuning.baseSize,
          riseDistance: _tuning.riseDistance,
          duration: _tuning.duration <= 0 ? 1.0 : _tuning.duration,
          maxOpacity: _tuning.opacity,
          windDriftSpeed: _tuning.windDriftSpeed,
          blobSeed: _random.nextInt(0x7FFFFFFF),
        ),
      );
    }
  }
}

/// Blob 구름 덩어리를 구성하는 타원 1개의 고정 형태 정보.
///
/// 파티클 생성 시 [blobSeed] 로 한 번만 결정되며, 생명주기 동안 변하지 않는다.
class _SmokeBlobLobe {
  const _SmokeBlobLobe({
    required this.offsetX,
    required this.offsetY,
    required this.widthScale,
    required this.heightScale,
    required this.rotation,
  });

  /// 중심 기준 상대 x 오프셋 (scale 배수).
  final double offsetX;

  /// 중심 기준 상대 y 오프셋 (scale 배수).
  final double offsetY;

  /// 타원 가로 반지름 배수.
  final double widthScale;

  /// 타원 세로 반지름 배수.
  final double heightScale;

  /// 타원 회전(라디안).
  final double rotation;
}

/// [seed] 로 결정되는 3~5개 타원으로 몽글몽글한 Blob 형태를 만든다.
List<_SmokeBlobLobe> _createSmokeBlobLobes(int seed) {
  final random = Random(seed);
  final lobeCount = 3 + random.nextInt(3);
  final lobes = <_SmokeBlobLobe>[];

  // 중앙 메인 타원.
  lobes.add(
    _SmokeBlobLobe(
      offsetX: (random.nextDouble() - 0.5) * 0.08,
      offsetY: (random.nextDouble() - 0.5) * 0.06,
      widthScale: 0.92 + random.nextDouble() * 0.14,
      heightScale: 0.72 + random.nextDouble() * 0.16,
      rotation: (random.nextDouble() - 0.5) * 0.22,
    ),
  );

  // 좌·우·위·뒤 보조 타원 템플릿 (seed 기반 미세 지터).
  const extraTemplates = <(double, double, double, double)>[
    (-0.36, 0.05, 0.50, 0.40),
    (0.34, 0.03, 0.46, 0.44),
    (-0.10, -0.26, 0.42, 0.36),
    (0.16, -0.16, 0.36, 0.32),
  ];

  for (var i = 1; i < lobeCount; i++) {
    final template = extraTemplates[i - 1];
    lobes.add(
      _SmokeBlobLobe(
        offsetX: template.$1 + (random.nextDouble() - 0.5) * 0.10,
        offsetY: template.$2 + (random.nextDouble() - 0.5) * 0.08,
        widthScale: template.$3 + (random.nextDouble() - 0.5) * 0.12,
        heightScale: template.$4 + (random.nextDouble() - 0.5) * 0.10,
        rotation: (random.nextDouble() - 0.5) * 0.32,
      ),
    );
  }

  return lobes;
}

/// 겹친 타원들로 말랑한 Blob 구름 덩어리를 그린다.
void _drawSmokeBlob(
  Canvas canvas,
  List<_SmokeBlobLobe> lobes,
  double scale,
  Paint paint,
) {
  for (final lobe in lobes) {
    canvas.save();
    canvas.translate(lobe.offsetX * scale, lobe.offsetY * scale);
    canvas.rotate(lobe.rotation);
    final width = lobe.widthScale * scale * 2;
    final height = lobe.heightScale * scale * 2;
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: width, height: height),
      paint,
    );
    canvas.restore();
  }
}

/// 굴뚝에서 천천히 올라오며 점점 투명해지고 커지는 연기 한 조각.
class _SmokePuffComponent extends PositionComponent {
  _SmokePuffComponent({
    required double startX,
    required double startY,
    required double baseSize,
    required double riseDistance,
    required double duration,
    required double maxOpacity,
    required double windDriftSpeed,
    required int blobSeed,
  }) : _startX = startX,
       _startY = startY,
       _baseSize = baseSize,
       _riseDistance = riseDistance,
       _duration = duration,
       _maxOpacity = maxOpacity,
       _windDriftSpeed = windDriftSpeed,
       _lobes = _createSmokeBlobLobes(blobSeed),
       super(
         anchor: Anchor.center,
         position: Vector2(startX, startY),
         priority: 3,
       );

  static const Color _smokeBaseColor = Color(0xFFECECEC);

  final double _startX;
  final double _startY;
  final double _baseSize;
  final double _riseDistance;
  final double _duration;
  final double _maxOpacity;
  final double _windDriftSpeed;
  final List<_SmokeBlobLobe> _lobes;

  double _elapsed = 0;
  double _currentScale = 0;
  double _currentOpacity = 0;

  @override
  void onMount() {
    super.onMount();
    _currentScale = _baseSize;
    _currentOpacity = _maxOpacity;
  }

  @override
  void render(Canvas canvas) {
    final paint = Paint()
      ..color = _smokeBaseColor.withValues(alpha: _currentOpacity)
      ..style = PaintingStyle.fill;
    _drawSmokeBlob(canvas, _lobes, _currentScale, paint);
  }

  @override
  void update(double dt) {
    super.update(dt);
    _elapsed += dt;
    final t = (_elapsed / _duration).clamp(0.0, 1.0);
    if (t >= 1.0) {
      removeFromParent();
      return;
    }

    // 위로 천천히 상승 + 바람에 의해 우측으로 drift.
    position.setValues(
      _startX + _windDriftSpeed * _elapsed,
      _startY - _riseDistance * t,
    );

    // 시간이 지날수록 1.0배 → 약 2.2배로 천천히 커진다.
    _currentScale = _baseSize * (1.0 + t * 1.2);

    // 시간이 지날수록 0 으로 사라진다(처음엔 약간 부드럽게).
    final fade = (1.0 - t);
    _currentOpacity = _maxOpacity * fade;
  }
}
