import 'dart:ui' show Image;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';

/// 스프라이트 시트 1프레임 크기 (텍스처 기준).
const double kPetSpriteFrameSize = 128;

/// Flame image loader 경로 prefix (`assets/images/` 제외).
String petFlameAssetPrefix({
  required String speciesCode,
  required String stageFolder,
}) {
  return 'pets/$speciesCode/$stageFolder';
}

/// adult 는 teen 폴더 asset 을 사용한다.
String petStageAssetFolder(String stage) {
  switch (stage) {
    case 'young':
      return 'young';
    case 'teen':
    case 'adult':
      return 'teen';
    case 'baby':
    default:
      return 'baby';
  }
}

/// 마당 표시 크기 (stage 기준). adult 도 teen 과 동일 96.
double petDisplaySizeForStage(String stage) {
  switch (stage) {
    case 'young':
      return 88;
    case 'teen':
    case 'adult':
      return 96;
    case 'baby':
    default:
      return 80;
  }
}

/// species + motion 기준 프레임 수.
///
/// 고양이(run)만 5프레임, 그 외는 4프레임.
int petSheetFrameCount({
  required String speciesCode,
  required String sheetFileName,
}) {
  final isCat = speciesCode == 'cat_rag' || speciesCode == 'cat_sco';
  if (isCat && sheetFileName == 'run_sheet.png') return 5;
  return 4;
}

const List<String> kPetSpriteSheetFiles = [
  'happy_sheet.png',
  'idle_sheet.png',
  'play_sheet.png',
  'run_sheet.png',
  'sit_sheet.png',
  'sitting_idle_sheet.png',
  'walk_sheet.png',
];

/// 종·단계별 스프라이트 시트 로더.
class PetSpriteAssets {
  PetSpriteAssets._({
    required this.speciesCode,
    required this.stageFolder,
    required this.happyAnimation,
    required this.idleAnimation,
    required this.walkAnimation,
    required this.runAnimation,
    required this.sitAnimation,
    required this.sittingIdleAnimation,
    required this.standAnimation,
    required this.playAnimation,
    required this.baseStepTime,
  });

  final String speciesCode;
  final String stageFolder;
  final SpriteAnimation happyAnimation;
  final SpriteAnimation idleAnimation;
  final SpriteAnimation walkAnimation;
  final SpriteAnimation runAnimation;
  final SpriteAnimation sitAnimation;
  final SpriteAnimation sittingIdleAnimation;
  final SpriteAnimation standAnimation;
  final SpriteAnimation playAnimation;
  final double baseStepTime;

  String get flamePrefix =>
      petFlameAssetPrefix(speciesCode: speciesCode, stageFolder: stageFolder);

  static Future<PetSpriteAssets> load(
    FlameGame game, {
    required String speciesCode,
    required String stageFolder,
    double baseStepTime = 0.14,
  }) async {
    final prefix = petFlameAssetPrefix(
      speciesCode: speciesCode,
      stageFolder: stageFolder,
    );
    debugPrint('PetSpriteAssets.load start (flame prefix: $prefix)');
    try {
      Future<Image> loadSheet(String file) => _loadImage(game, '$prefix/$file');

      final happyImage = await loadSheet('happy_sheet.png');
      final idleImage = await loadSheet('idle_sheet.png');
      final walkImage = await loadSheet('walk_sheet.png');
      final runImage = await loadSheet('run_sheet.png');
      final sitImage = await loadSheet('sit_sheet.png');
      final sittingIdleImage = await loadSheet('sitting_idle_sheet.png');
      final playImage = await loadSheet('play_sheet.png');

      final sitFrames = _framesFromSheet(
        sitImage,
        frameCount: petSheetFrameCount(
          speciesCode: speciesCode,
          sheetFileName: 'sit_sheet.png',
        ),
      );

      SpriteAnimation sheetAnim(
        Image image, {
        required String fileName,
        required bool loop,
      }) {
        final amount = petSheetFrameCount(
          speciesCode: speciesCode,
          sheetFileName: fileName,
        );
        return SpriteAnimation.fromFrameData(
          image,
          SpriteAnimationData.sequenced(
            amount: amount,
            stepTime: baseStepTime,
            textureSize: Vector2.all(kPetSpriteFrameSize),
            loop: loop,
          ),
        );
      }

      debugPrint('PetSpriteAssets.load success ($prefix)');
      return PetSpriteAssets._(
        speciesCode: speciesCode,
        stageFolder: stageFolder,
        happyAnimation: sheetAnim(
          happyImage,
          fileName: 'happy_sheet.png',
          loop: false,
        ),
        idleAnimation: sheetAnim(
          idleImage,
          fileName: 'idle_sheet.png',
          loop: true,
        ),
        walkAnimation: sheetAnim(
          walkImage,
          fileName: 'walk_sheet.png',
          loop: true,
        ),
        runAnimation: sheetAnim(
          runImage,
          fileName: 'run_sheet.png',
          loop: true,
        ),
        sitAnimation: sheetAnim(
          sitImage,
          fileName: 'sit_sheet.png',
          loop: false,
        ),
        sittingIdleAnimation: sheetAnim(
          sittingIdleImage,
          fileName: 'sitting_idle_sheet.png',
          loop: true,
        ),
        standAnimation: SpriteAnimation.spriteList(
          sitFrames.reversed.toList(),
          stepTime: baseStepTime,
          loop: false,
        ),
        playAnimation: sheetAnim(
          playImage,
          fileName: 'play_sheet.png',
          loop: false,
        ),
        baseStepTime: baseStepTime,
      );
    } catch (e, st) {
      debugPrint('PetSpriteAssets.load failed ($prefix): $e\n$st');
      rethrow;
    }
  }

  static Future<void> preflightAssets(
    FlameGame game, {
    required String speciesCode,
    required String stageFolder,
  }) async {
    final prefix = petFlameAssetPrefix(
      speciesCode: speciesCode,
      stageFolder: stageFolder,
    );
    debugPrint('PetSpriteAssets preflight start ($prefix)');
    for (final file in kPetSpriteSheetFiles) {
      await _loadImage(game, '$prefix/$file');
    }
    debugPrint('PetSpriteAssets preflight success ($prefix)');
  }

  static Future<Image> _loadImage(FlameGame game, String flameAssetPath) async {
    debugPrint('PetSpriteAssets loading: $flameAssetPath');
    try {
      final sprite = await game.loadSprite(flameAssetPath);
      return sprite.image;
    } catch (e) {
      debugPrint('PetSpriteAssets load failed: $flameAssetPath / $e');
      rethrow;
    }
  }

  static List<Sprite> _framesFromSheet(
    Image image, {
    required int frameCount,
  }) {
    return List.generate(
      frameCount,
      (i) => Sprite(
        image,
        srcPosition: Vector2(i * kPetSpriteFrameSize, 0),
        srcSize: Vector2.all(kPetSpriteFrameSize),
      ),
    );
  }
}
