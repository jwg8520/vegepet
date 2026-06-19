import 'dart:ui' show Image;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';

/// Flame image loader 기준 cat_sco baby 경로 prefix (`assets/images/` 제외).
const String kCatScoBabyFlamePrefix = 'pets/cat_sco/baby';

/// cat_sco baby sprite / sheet 파일명 (Flame load 경로 = prefix + 파일명).
const List<String> kCatScoBabyAssetFiles = [
  'idle_sheet.png',
  'walk_sheet.png',
  'run_sheet.png',
  'play_sheet.png',
  'lie_down_sheet.png',
  'lying_idle_sheet.png',
  'kneading_sheet.png',
];

/// cat_sco baby 전용 sprite / sprite sheet 로더.
class CatScoBabyAssets {
  CatScoBabyAssets._({
    required this.idleAnimation,
    required this.walkAnimation,
    required this.runAnimation,
    required this.lieDownAnimation,
    required this.lyingIdleAnimation,
    required this.standUpAnimation,
    required this.kneadingAnimation,
    required this.playAnimation,
    required this.baseStepTime,
  });

  final SpriteAnimation idleAnimation;
  final SpriteAnimation walkAnimation;
  final SpriteAnimation runAnimation;
  final SpriteAnimation lieDownAnimation;
  final SpriteAnimation lyingIdleAnimation;
  final SpriteAnimation standUpAnimation;
  final SpriteAnimation kneadingAnimation;
  final SpriteAnimation playAnimation;
  final double baseStepTime;

  static const double frameSize = 80;
  static const int sheetFrameCount = 4;

  /// [baseStepTime] 은 4프레임 sheet 1사이클 기준 stepTime (기본 0.14초/프레임).
  static Future<CatScoBabyAssets> load(
    FlameGame game, {
    double baseStepTime = 0.14,
  }) async {
    debugPrint(
      'CatScoBabyAssets.load start (flame prefix: $kCatScoBabyFlamePrefix)',
    );
    try {
      final idleImage =
          await _loadImage(game, '$kCatScoBabyFlamePrefix/idle_sheet.png');
      final walkImage =
          await _loadImage(game, '$kCatScoBabyFlamePrefix/walk_sheet.png');
      final runImage =
          await _loadImage(game, '$kCatScoBabyFlamePrefix/run_sheet.png');
      final lieDownImage =
          await _loadImage(game, '$kCatScoBabyFlamePrefix/lie_down_sheet.png');
      final lyingIdleImage = await _loadImage(
        game,
        '$kCatScoBabyFlamePrefix/lying_idle_sheet.png',
      );
      final kneadingImage =
          await _loadImage(game, '$kCatScoBabyFlamePrefix/kneading_sheet.png');
      final playImage =
          await _loadImage(game, '$kCatScoBabyFlamePrefix/play_sheet.png');

      final lieDownFrames = _framesFromSheet(lieDownImage);

      SpriteAnimation sheetAnim(
        Image image, {
        required bool loop,
      }) {
        return SpriteAnimation.fromFrameData(
          image,
          SpriteAnimationData.sequenced(
            amount: sheetFrameCount,
            stepTime: baseStepTime,
            textureSize: Vector2(frameSize, frameSize),
            loop: loop,
          ),
        );
      }

      debugPrint('CatScoBabyAssets.load success');
      return CatScoBabyAssets._(
        idleAnimation: sheetAnim(idleImage, loop: true),
        walkAnimation: sheetAnim(walkImage, loop: true),
        runAnimation: sheetAnim(runImage, loop: true),
        lieDownAnimation: sheetAnim(lieDownImage, loop: false),
        lyingIdleAnimation: sheetAnim(lyingIdleImage, loop: true),
        standUpAnimation: SpriteAnimation.spriteList(
          lieDownFrames.reversed.toList(),
          stepTime: baseStepTime,
          loop: false,
        ),
        kneadingAnimation: sheetAnim(kneadingImage, loop: false),
        playAnimation: sheetAnim(playImage, loop: false),
        baseStepTime: baseStepTime,
      );
    } catch (e, st) {
      debugPrint(
        'CatScoBabyAssets.load failed (flame prefix: $kCatScoBabyFlamePrefix): $e\n$st',
      );
      rethrow;
    }
  }

  /// 분양 전 asset bundle 등록 여부 preflight (7종 순차 로드).
  static Future<void> preflightAssets(FlameGame game) async {
    debugPrint(
      'CatScoBabyAssets preflight start (flame prefix: $kCatScoBabyFlamePrefix)',
    );
    for (final file in kCatScoBabyAssetFiles) {
      await _loadImage(game, '$kCatScoBabyFlamePrefix/$file');
    }
    debugPrint('CatScoBabyAssets preflight success');
  }

  /// yard 배경과 동일하게 [FlameGame.loadSprite] 경로를 사용한다.
  static Future<Image> _loadImage(FlameGame game, String flameAssetPath) async {
    debugPrint('VegePetComponent loading asset: $flameAssetPath');
    try {
      final sprite = await game.loadSprite(flameAssetPath);
      debugPrint('VegePetComponent loaded asset: $flameAssetPath');
      return sprite.image;
    } catch (e) {
      debugPrint('VegePetComponent asset load failed: $flameAssetPath / $e');
      rethrow;
    }
  }

  static List<Sprite> _framesFromSheet(Image image) {
    return List.generate(
      sheetFrameCount,
      (i) => Sprite(
        image,
        srcPosition: Vector2(i * frameSize, 0),
        srcSize: Vector2(frameSize, frameSize),
      ),
    );
  }
}
