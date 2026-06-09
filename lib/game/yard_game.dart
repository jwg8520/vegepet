import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';

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

/// 구름 4개 초기 튜닝 값. x/y/width/speed 만 바꿔가며 조정한다.
const List<CloudTuning> kCloudTunings = [
  CloudTuning(
    asset: 'yard/cloud_01.png',
    x: -40,
    y: 12,
    width: 260,
    speed: 6,
  ),
  CloudTuning(
    asset: 'yard/cloud_02.png',
    x: 180,
    y: 34,
    width: 320,
    speed: 4,
  ),
  CloudTuning(
    asset: 'yard/cloud_03.png',
    x: 430,
    y: 62,
    width: 280,
    speed: 5,
  ),
  CloudTuning(
    asset: 'yard/cloud_04.png',
    x: 680,
    y: 92,
    width: 340,
    speed: 3.5,
  ),
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
    await super.onLoad();

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
    for (final tuning in kCloudTunings) {
      final cloudSprite = await loadSprite(tuning.asset);
      world.add(_CloudComponent(tuning: tuning, sprite: cloudSprite));
    }

    // 2) 마당 지면(오두막 포함): 하늘/구름 위에 844 x 390 전체로 배치.
    _addFullCanvasSprite(groundSprite, priority: 2);
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
  _CloudComponent({required CloudTuning tuning, required Sprite sprite})
    : _speed = tuning.speed,
      super(
        sprite: sprite,
        priority: 1,
        position: Vector2(tuning.x, tuning.y),
        size: _sizeFromWidth(sprite, tuning.width),
        anchor: Anchor.topLeft,
      );

  final double _speed;

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
    position.x += _speed * dt;

    final cloudWidth = size.x;
    if (_speed >= 0) {
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
