import 'dart:async';
import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vegepet/game/pet_motion.dart';
import 'package:vegepet/game/vegepet_component.dart';

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

/// 오두막 접근 불가 충돌 영역(Hexagon Polygon) 튜닝 값.
///
/// - 844 x 390 논리 좌표 기준. [x]/[y]/[width]/[height] 는 육각형 bounding box 이다.
/// - [topInset]/[bottomInset] 으로 위·아래 좌우 모서리가 안쪽으로 들어가 2.5D
///   아이소메트릭에 맞는 육각형 모양을 만든다.
/// - 실제 이동 충돌 반응은 다음 베지펫 이동 단계에서 [isInsideHutCollision] 으로 연결.
class HutCollisionTuning {
  const HutCollisionTuning({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.topInset,
    required this.bottomInset,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  /// 육각형 위쪽 모서리 사선 깊이. 클수록 위쪽 좌우 꼭짓점이 안쪽으로 들어온다.
  final double topInset;

  /// 육각형 아래쪽 모서리 사선 깊이. 클수록 아래쪽 좌우 꼭짓점이 안쪽으로 들어온다.
  final double bottomInset;
}

/// debug 튜닝 패널에서 실시간으로 변경하는 오두막 충돌 영역 런타임 설정.
class HutCollisionRuntimeTuning {
  HutCollisionRuntimeTuning({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.topInset,
    required this.bottomInset,
  });

  double x;
  double y;
  double width;
  double height;
  double topInset;
  double bottomInset;
}

/// 오두막 충돌 영역 초기값. 실제 위치는 debug 튜닝 패널로 조정한다(임시값).
const HutCollisionTuning kHutCollisionTuning = HutCollisionTuning(
  x: 349.5,
  y: 29.4,
  width: 221.1,
  height: 176.3,
  topInset: 50.3,
  bottomInset: 23.7,
);

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

/// 베지펫이 이동 가능한 마당 영역 (844×390, 추후 튜닝).
final List<Vector2> kYardWalkableAreaPolygon = [
  Vector2(0, 145),
  Vector2(230, 55),
  Vector2(844, 145),
  Vector2(844, 390),
  Vector2(0, 390),
];

/// VegePet 2.5D 아이소메트릭 마당 Flame 게임 (1단계: 배경 + 구름).
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

  final HutCollisionRuntimeTuning _hutCollisionTuning =
      HutCollisionRuntimeTuning(
        x: kHutCollisionTuning.x,
        y: kHutCollisionTuning.y,
        width: kHutCollisionTuning.width,
        height: kHutCollisionTuning.height,
        topInset: kHutCollisionTuning.topInset,
        bottomInset: kHutCollisionTuning.bottomInset,
      );
  _HutCollisionDebugComponent? _hutCollisionDebug;

  VegePetComponent? _vegePetComponent;
  String? _activePetUserId;
  String? _lastPetSpawnError;
  Future<bool>? _petSpawnInFlight;
  String? _petSpawnInFlightUserId;

  final Completer<void> _onLoadCompleter = Completer<void>();

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
  // 오두막 충돌 영역 API (2단계). 실제 이동 충돌은 다음 베지펫 이동 단계에서 연결.
  // ---------------------------------------------------------------------------

  /// debug 튜닝 패널에서 접근하는 오두막 충돌 영역 런타임 설정.
  HutCollisionRuntimeTuning get hutCollisionTuning => _hutCollisionTuning;

  /// 현재 오두막 충돌 육각형의 bounding box(844×390 논리 좌표).
  Rect get hutCollisionRect => Rect.fromLTWH(
    _hutCollisionTuning.x,
    _hutCollisionTuning.y,
    _hutCollisionTuning.width,
    _hutCollisionTuning.height,
  );

  /// 현재 오두막 충돌 육각형 꼭짓점 6개(844×390 논리 좌표, 시계 방향).
  List<Vector2> get hutCollisionPolygonPoints {
    final t = _hutCollisionTuning;
    final topInset = t.topInset.clamp(0.0, t.width / 2);
    final bottomInset = t.bottomInset.clamp(0.0, t.width / 2);
    final midY = t.y + t.height * 0.5;

    return [
      Vector2(t.x + topInset, t.y),
      Vector2(t.x + t.width - topInset, t.y),
      Vector2(t.x + t.width, midY),
      Vector2(t.x + t.width - bottomInset, t.y + t.height),
      Vector2(t.x + bottomInset, t.y + t.height),
      Vector2(t.x, midY),
    ];
  }

  /// [point] 가 오두막 충돌 육각형 안에 있는지 여부.
  bool isInsideHutCollision(Vector2 point) =>
      _isPointInsidePolygon(point, hutCollisionPolygonPoints);

  /// 오두막 충돌 polygon 중심 (빠져나오는 방향 판정용).
  Vector2 get hutCollisionCenter {
    final pts = hutCollisionPolygonPoints;
    if (pts.isEmpty) return Vector2.zero();
    var sx = 0.0;
    var sy = 0.0;
    for (final p in pts) {
      sx += p.x;
      sy += p.y;
    }
    return Vector2(sx / pts.length, sy / pts.length);
  }

  double distanceToHutCenter(Vector2 point) =>
      (point - hutCollisionCenter).length;

  /// [point] 가 마당 이동 가능 polygon 안에 있는지 여부.
  bool isInsideWalkableArea(Vector2 point) =>
      _isPointInsidePolygon(point, kYardWalkableAreaPolygon);

  /// 베지펫 이동 가능 여부 (walkable + 오두막 충돌 회피).
  bool canPetMoveTo(Vector2 current, Vector2 next) {
    if (!isInsideWalkableArea(next)) return false;

    final currentInsideHut = isInsideHutCollision(current);
    final nextInsideHut = isInsideHutCollision(next);
    if (!nextInsideHut) return true;
    if (currentInsideHut) {
      return distanceToHutCenter(next) > distanceToHutCenter(current);
    }
    return false;
  }

  bool _isVegePetAlive(VegePetComponent? pet) {
    if (pet == null) return false;
    return pet.isMounted || pet.parent != null;
  }

  bool get hasActiveVegePet => _isVegePetAlive(_vegePetComponent);

  Future<void> _ensureGameLoaded() async {
    if (!_onLoadCompleter.isCompleted) {
      debugPrint('YardGame: waiting for onLoad before pet spawn');
      await _onLoadCompleter.future;
    }
  }

  Future<bool> _spawnCatScoBabyComponent({
    required String userPetId,
    bool isDebugOnly = false,
  }) async {
    await removeActivePetComponent();

    final component = VegePetComponent(
      userPetId: userPetId,
      isDebugOnly: isDebugOnly,
    );
    _vegePetComponent = component;
    _activePetUserId = userPetId;

    await world.add(component);
    await Future<void>.delayed(Duration.zero);

    final alive = _isVegePetAlive(component);
    if (!alive) {
      _lastPetSpawnError =
          'VegePetComponent was not mounted after world.add (mounted=${component.isMounted}, parent=${component.parent != null})';
      debugPrint('YardGame: $_lastPetSpawnError');
      _vegePetComponent = null;
      _activePetUserId = null;
      return false;
    }

    debugPrint(
      'YardGame: cat_sco baby spawned, userPetId=$userPetId, mounted=${component.isMounted}, parent=${component.parent != null}',
    );
    return true;
  }

  /// cat_sco baby 펫을 마당에 표시한다. 동일 userPetId 가 이미 있으면 skip.
  Future<bool> showCatScoBabyPet({required String userPetId}) async {
    if (_petSpawnInFlight != null && _petSpawnInFlightUserId == userPetId) {
      debugPrint(
        'YardGame: showCatScoBabyPet join in-flight spawn (userPetId=$userPetId)',
      );
      return _petSpawnInFlight!;
    }

    final future = _showCatScoBabyPetImpl(userPetId: userPetId);
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

  Future<bool> _showCatScoBabyPetImpl({required String userPetId}) async {
    try {
      _lastPetSpawnError = null;
      await _ensureGameLoaded();

      if (_vegePetComponent != null &&
          _activePetUserId == userPetId &&
          _isVegePetAlive(_vegePetComponent)) {
        debugPrint(
          'YardGame: cat_sco baby already shown (userPetId=$userPetId)',
        );
        return true;
      }

      return await _spawnCatScoBabyComponent(userPetId: userPetId);
    } catch (e, st) {
      _lastPetSpawnError = e.toString();
      debugPrint('YardGame.showCatScoBabyPet failed: $e\n$st');
      _vegePetComponent = null;
      _activePetUserId = null;
      return false;
    }
  }

  /// debug 전용: DB 변경 없이 cat_sco baby 를 스폰한다.
  Future<bool> showCatScoBabyPetDebug() async {
    const debugId = 'debug-cat-sco-baby';
    if (_petSpawnInFlight != null && _petSpawnInFlightUserId == debugId) {
      return _petSpawnInFlight!;
    }

    final future = _showCatScoBabyPetDebugImpl();
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

  Future<bool> _showCatScoBabyPetDebugImpl() async {
    try {
      _lastPetSpawnError = null;
      await _ensureGameLoaded();

      final debugId = 'debug-cat-sco-baby';
      if (_vegePetComponent != null &&
          _activePetUserId == debugId &&
          _isVegePetAlive(_vegePetComponent)) {
        debugPrint('YardGame: debug cat_sco baby already shown');
        return true;
      }

      final ok = await _spawnCatScoBabyComponent(
        userPetId: debugId,
        isDebugOnly: true,
      );
      if (ok) {
        debugPrint('YardGame: debug cat_sco baby spawned');
      } else {
        debugPrint(
          'YardGame: debug cat_sco baby spawn failed, error=$_lastPetSpawnError',
        );
      }
      return ok;
    } catch (e, st) {
      _lastPetSpawnError = e.toString();
      debugPrint('YardGame.showCatScoBabyPetDebug failed: $e\n$st');
      _vegePetComponent = null;
      _activePetUserId = null;
      return false;
    }
  }

  /// 활성 Flame 펫 컴포넌트를 제거한다.
  Future<void> removeActivePetComponent() async {
    _vegePetComponent?.removeFromParent();
    _vegePetComponent = null;
    _activePetUserId = null;
  }

  /// 활성 펫에 모션을 발동한다. 펫이 없으면 no-op.
  void playPetMotion(
    PetMotion motion, {
    double speedMultiplier = 1.0,
    int repeatCount = 1,
  }) {
    final pet = _vegePetComponent;
    if (pet == null || !_isVegePetAlive(pet)) return;
    unawaited(
      pet.playMotion(
        motion,
        speedMultiplier: speedMultiplier,
        repeatCount: repeatCount,
      ),
    );
  }

  /// 오두막 충돌 영역 값을 즉시 반영한다(debug polygon overlay 도 즉시 갱신).
  void updateHutCollisionTuning({
    double? x,
    double? y,
    double? width,
    double? height,
    double? topInset,
    double? bottomInset,
  }) {
    if (x != null) _hutCollisionTuning.x = x;
    if (y != null) _hutCollisionTuning.y = y;
    if (width != null) _hutCollisionTuning.width = width;
    if (height != null) _hutCollisionTuning.height = height;
    if (topInset != null) _hutCollisionTuning.topInset = topInset;
    if (bottomInset != null) _hutCollisionTuning.bottomInset = bottomInset;
    _refreshHutCollisionDebugOverlay();
  }

  /// debug 전용 육각형 충돌 overlay 를 최신 polygon points 로 다시 만든다.
  void _refreshHutCollisionDebugOverlay() {
    if (!kDebugMode) return;
    _hutCollisionDebug?.removeFromParent();
    final debug = _HutCollisionDebugComponent(
      points: hutCollisionPolygonPoints,
    );
    _hutCollisionDebug = debug;
    world.add(debug);
  }

  /// 현재 오두막 충돌 값을 [kHutCollisionTuning] const 코드 형태로 반환한다.
  String buildHutCollisionDebugText() {
    final t = _hutCollisionTuning;
    final buffer = StringBuffer(
      'const HutCollisionTuning kHutCollisionTuning = HutCollisionTuning(\n',
    );
    buffer.writeln('  x: ${_formatTuningNumber(t.x)},');
    buffer.writeln('  y: ${_formatTuningNumber(t.y)},');
    buffer.writeln('  width: ${_formatTuningNumber(t.width)},');
    buffer.writeln('  height: ${_formatTuningNumber(t.height)},');
    buffer.writeln('  topInset: ${_formatTuningNumber(t.topInset)},');
    buffer.writeln('  bottomInset: ${_formatTuningNumber(t.bottomInset)},');
    buffer.write(');');
    return buffer.toString();
  }

  /// ray casting 으로 [point] 가 [polygon] 내부인지 판정한다.
  static bool _isPointInsidePolygon(Vector2 point, List<Vector2> polygon) {
    if (polygon.length < 3) return false;

    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].x;
      final yi = polygon[i].y;
      final xj = polygon[j].x;
      final yj = polygon[j].y;
      final denom = yj - yi;

      final intersects =
          ((yi > point.y) != (yj > point.y)) &&
          (point.x <
              (xj - xi) * (point.y - yi) / (denom == 0 ? 0.000001 : denom) +
                  xi);
      if (intersects) inside = !inside;
    }
    return inside;
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
    buffer.writeln('  windDriftSpeed: ${_formatTuningNumber(t.windDriftSpeed)},');
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
  // 2.5D 아이소메트릭 준비 (이번 단계에서는 정의만 남기고 사용하지 않음).
  //
  // walkableArea: 향후 베지펫이 이동 가능한 영역. 사각형이 아니라 사선 원근감을
  //   가진 polygon(육각/마름모 형태의 타일 마당) 기반으로 정의될 예정이다.
  //   하늘 영역과 yard_ground 바깥 영역은 접근 불가 영역으로 처리한다.
  //
  // hutCollisionPolygon: 오두막은 yard_ground 이미지 안에 포함되어 있으므로
  //   별도 SpriteComponent 로 만들지 않는다. 향후 invisible collision 영역
  //   (hutCollisionRect 또는 hutCollisionPolygon) 으로 접근 불가 처리할 예정이다.
  //
  // 예) static const List<Offset> walkableAreaPolygon = [...];
  //     static const List<Offset> hutCollisionPolygon = [...];
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

      // 3) 굴뚝 연기: yard_ground(priority 2) 위에 표시. release 에서도 보인다.
      world.add(_SmokeEmitterComponent(tuning: _smokeTuning));

      // 4) 오두막 충돌 영역 debug polygon overlay: debug 빌드에서만 추가한다.
      //    release 에서는 위젯/컴포넌트 트리에 들어가지 않아 절대 보이지 않는다.
      if (kDebugMode) {
        _refreshHutCollisionDebugOverlay();
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
    final aspect =
        srcSize.x <= 0 || srcSize.y <= 0 ? 1.0 : srcSize.x / srcSize.y;
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

/// 오두막 충돌 육각형을 시각화하는 debug 전용 반투명 polygon.
///
/// debug 빌드에서만 [YardGame._refreshHutCollisionDebugOverlay] 로 world 에
/// 추가된다. release 에서는 절대 생성/추가되지 않는다.
class _HutCollisionDebugComponent extends PolygonComponent {
  _HutCollisionDebugComponent({required List<Vector2> points})
    : super(
        points,
        // position 을 지정하지 않아야 Flame 이 bounding box topLeft 로
        // position 을 자동 설정한다. position: Vector2.zero() 를 넘기면
        // manuallyPositioned=true 가 되어 x/y 튜닝 시 polygon 이 이동하지 않는다.
        anchor: Anchor.topLeft,
        priority: 5,
        paint: Paint()..color = const Color(0x55FF5722),
      );
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
