import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vegepet/game/pet_motion.dart';
import 'package:vegepet/game/pet_sprite_assets.dart';

/// 모션 튜닝 대상 종.
const List<String> kPetMotionSpeciesCodes = [
  'cat_rag',
  'cat_sco',
  'dog_bic',
  'dog_pom',
];

/// 모션 튜닝 대상 단계 폴더 (adult → teen).
const List<String> kPetMotionStageFolders = [
  'baby',
  'young',
  'teen',
];

/// species + stage + motion → prefs/map 키.
String petMotionTuneKey({
  required String speciesCode,
  required String stage,
  required PetMotion motion,
}) {
  final folder = petStageAssetFolder(stage);
  return '$speciesCode|$folder|${motion.name}';
}

/// 모션별 spd/rep 설정 (한 슬롯).
class PetMotionTuneConfig {
  PetMotionTuneConfig({
    required this.speedMultiplier,
    required this.repeatCount,
  });

  double speedMultiplier;
  int repeatCount;

  void copyFrom(PetMotionTuneConfig other) {
    speedMultiplier = other.speedMultiplier;
    repeatCount = other.repeatCount;
  }

  PetMotionTuneConfig clone() {
    return PetMotionTuneConfig(
      speedMultiplier: speedMultiplier,
      repeatCount: repeatCount,
    );
  }

  void resetToDefaultFor(PetMotion motion) {
    final d = kPetMotionBuiltInDefaultFor(motion);
    speedMultiplier = d.speedMultiplier;
    repeatCount = d.repeatCount;
  }

  Map<String, dynamic> toJson() {
    return {
      'speedMultiplier': speedMultiplier,
      'repeatCount': repeatCount,
    };
  }

  factory PetMotionTuneConfig.fromJson(
    Map<String, dynamic> json, {
    required PetMotion motion,
  }) {
    final d = kPetMotionBuiltInDefaultFor(motion);
    return PetMotionTuneConfig(
      speedMultiplier:
          (json['speedMultiplier'] as num?)?.toDouble() ?? d.speedMultiplier,
      repeatCount: (json['repeatCount'] as num?)?.toInt() ?? d.repeatCount,
    );
  }
}

final PetMotionTuneConfig _kPetMotionFallbackSeed = PetMotionTuneConfig(
  speedMultiplier: 1.0,
  repeatCount: 1,
);

/// 빌트인 기본값 시드 (종·단계 공통). 런타임에 mutate 하지 말 것 — 항상 clone 해서 사용.
final Map<PetMotion, PetMotionTuneConfig> kPetMotionBuiltInDefaults = {
  PetMotion.happy: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 1),
  PetMotion.idle: PetMotionTuneConfig(speedMultiplier: 0.7, repeatCount: 1),
  PetMotion.play: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 6),
  PetMotion.run: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 1),
  PetMotion.sit: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 1),
  PetMotion.sittingIdle: PetMotionTuneConfig(
    speedMultiplier: 0.7,
    repeatCount: 1,
  ),
  PetMotion.walk: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 1),
  PetMotion.stand: PetMotionTuneConfig(speedMultiplier: 1.0, repeatCount: 1),
};

PetMotionTuneConfig kPetMotionBuiltInDefaultFor(PetMotion motion) {
  final d = kPetMotionBuiltInDefaults[motion] ?? _kPetMotionFallbackSeed;
  return d.clone();
}

/// 하위 호환 alias.
PetMotionTuneConfig kPetMotionDefaultTuningFor(PetMotion motion) {
  return kPetMotionBuiltInDefaultFor(motion);
}

/// 종×단계×모션 튜닝 저장소.
class PetMotionTuneStore {
  PetMotionTuneStore() {
    ensureAllSlots();
  }

  final Map<String, PetMotionTuneConfig> _byKey = {};

  Map<String, PetMotionTuneConfig> get entries => Map.unmodifiable(_byKey);

  void ensureAllSlots() {
    for (final species in kPetMotionSpeciesCodes) {
      for (final stage in kPetMotionStageFolders) {
        for (final motion in PetMotion.values) {
          final key = petMotionTuneKey(
            speciesCode: species,
            stage: stage,
            motion: motion,
          );
          _byKey.putIfAbsent(
            key,
            () => kPetMotionBuiltInDefaultFor(motion),
          );
        }
      }
    }
  }

  PetMotionTuneConfig forPet({
    required String speciesCode,
    required String stage,
    required PetMotion motion,
  }) {
    final key = petMotionTuneKey(
      speciesCode: speciesCode,
      stage: stage,
      motion: motion,
    );
    return _byKey.putIfAbsent(
      key,
      () => kPetMotionBuiltInDefaultFor(motion),
    );
  }

  void applyAll(PetMotionTuneStore other) {
    for (final entry in other._byKey.entries) {
      final existing = _byKey.putIfAbsent(
        entry.key,
        () => entry.value.clone(),
      );
      existing.copyFrom(entry.value);
    }
    ensureAllSlots();
  }

  void resetSlot({
    required String speciesCode,
    required String stage,
    required PetMotion motion,
  }) {
    forPet(
      speciesCode: speciesCode,
      stage: stage,
      motion: motion,
    ).resetToDefaultFor(motion);
  }

  void resetSpeciesStage({
    required String speciesCode,
    required String stage,
  }) {
    for (final motion in PetMotion.values) {
      resetSlot(speciesCode: speciesCode, stage: stage, motion: motion);
    }
  }

  void resetAllToDefaults() {
    ensureAllSlots();
    for (final species in kPetMotionSpeciesCodes) {
      for (final stage in kPetMotionStageFolders) {
        for (final motion in PetMotion.values) {
          resetSlot(speciesCode: species, stage: stage, motion: motion);
        }
      }
    }
  }
}

/// SharedPreferences 저장/복원.
class PetMotionTunePreferences {
  static const String keyMapJson = 'debug_pet_motion_tune_map_v1';

  static Future<PetMotionTuneStore> load() async {
    final store = PetMotionTuneStore();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyMapJson);
      if (raw == null || raw.isEmpty) return store;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return store;

      for (final entry in decoded.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is! Map) continue;
        final parts = key.split('|');
        if (parts.length != 3) continue;
        final motionName = parts[2];
        PetMotion? motion;
        for (final m in PetMotion.values) {
          if (m.name == motionName) {
            motion = m;
            break;
          }
        }
        if (motion == null) continue;
        store._byKey[key] = PetMotionTuneConfig.fromJson(
          Map<String, dynamic>.from(value),
          motion: motion,
        );
      }
      store.ensureAllSlots();
    } catch (e) {
      debugPrint('PetMotionTunePreferences.load failed: $e');
      store.resetAllToDefaults();
    }
    return store;
  }

  static Future<void> save(PetMotionTuneStore store) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      store.ensureAllSlots();
      final map = <String, dynamic>{};
      for (final entry in store._byKey.entries) {
        map[entry.key] = entry.value.toJson();
      }
      await prefs.setString(keyMapJson, jsonEncode(map));
    } catch (e) {
      debugPrint('PetMotionTunePreferences.save failed: $e');
    }
  }
}
