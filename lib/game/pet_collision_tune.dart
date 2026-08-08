import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vegepet/game/pet_sprite_assets.dart';

/// 폴백/하위 호환용 (baby 표 기준).
const double kPetCollisionDefaultWidth = 34;
const double kPetCollisionDefaultHeight = 18;
const double kPetCollisionDefaultOffsetX = -0.4;
const double kPetCollisionDefaultOffsetY = -13.9;

/// 튜닝 대상 종.
const List<String> kPetCollisionSpeciesCodes = [
  'cat_rag',
  'cat_sco',
  'dog_bic',
  'dog_pom',
];

/// 튜닝 대상 단계 폴더 (adult → teen).
const List<String> kPetCollisionStageFolders = [
  'baby',
  'young',
  'teen',
];

String petCollisionTuneKey({
  required String speciesCode,
  required String stage,
}) {
  final folder = petStageAssetFolder(stage);
  return '$speciesCode|$folder';
}

PetCollisionTuneConfig _collisionSpec({
  required double w,
  required double h,
  required double oX,
  required double oY,
}) {
  return PetCollisionTuneConfig(
    width: w,
    height: h,
    offsetX: oX,
    offsetY: oY,
  );
}

/// 표 기준 빌트인 기본값 (종×단계). 4종 동일 스펙. 런타임 mutate 금지 — clone 사용.
PetCollisionTuneConfig kPetCollisionBuiltInDefaultFor({
  required String speciesCode,
  required String stage,
}) {
  final folder = petStageAssetFolder(stage);
  switch (folder) {
    case 'young':
      return _collisionSpec(w: 39.1, h: 20.5, oX: 0.4, oY: -17.7).clone();
    case 'teen':
      return _collisionSpec(w: 43.6, h: 23.2, oX: 0, oY: -19.8).clone();
    case 'baby':
    default:
      return _collisionSpec(w: 34, h: 18, oX: -0.4, oY: -13.9).clone();
  }
}

/// 종×단계 collision footprint 한 슬롯.
class PetCollisionTuneConfig {
  PetCollisionTuneConfig({
    this.width = kPetCollisionDefaultWidth,
    this.height = kPetCollisionDefaultHeight,
    this.offsetX = kPetCollisionDefaultOffsetX,
    this.offsetY = kPetCollisionDefaultOffsetY,
  });

  double width;
  double height;
  double offsetX;
  double offsetY;

  void resetToDefaultFor({
    required String speciesCode,
    required String stage,
  }) {
    final d = kPetCollisionBuiltInDefaultFor(
      speciesCode: speciesCode,
      stage: stage,
    );
    width = d.width;
    height = d.height;
    offsetX = d.offsetX;
    offsetY = d.offsetY;
  }

  /// 하위 호환: baby 폴백 기본값으로 리셋.
  void resetToDefaults() {
    resetToDefaultFor(speciesCode: 'cat_sco', stage: 'baby');
  }

  void copyFrom(PetCollisionTuneConfig other) {
    width = other.width;
    height = other.height;
    offsetX = other.offsetX;
    offsetY = other.offsetY;
  }

  PetCollisionTuneConfig clone() {
    return PetCollisionTuneConfig(
      width: width,
      height: height,
      offsetX: offsetX,
      offsetY: offsetY,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'width': width,
      'height': height,
      'offsetX': offsetX,
      'offsetY': offsetY,
    };
  }

  factory PetCollisionTuneConfig.fromJson(
    Map<String, dynamic> json, {
    String speciesCode = 'cat_sco',
    String stage = 'baby',
  }) {
    final d = kPetCollisionBuiltInDefaultFor(
      speciesCode: speciesCode,
      stage: stage,
    );
    return PetCollisionTuneConfig(
      width: (json['width'] as num?)?.toDouble() ?? d.width,
      height: (json['height'] as num?)?.toDouble() ?? d.height,
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? d.offsetX,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? d.offsetY,
    );
  }
}

/// 종×단계 collision 튜닝 저장소.
class PetCollisionTuneStore {
  PetCollisionTuneStore() {
    ensureAllSlots();
  }

  final Map<String, PetCollisionTuneConfig> _byKey = {};

  Map<String, PetCollisionTuneConfig> get entries =>
      Map.unmodifiable(_byKey);

  void ensureAllSlots() {
    for (final species in kPetCollisionSpeciesCodes) {
      for (final stage in kPetCollisionStageFolders) {
        final key = petCollisionTuneKey(speciesCode: species, stage: stage);
        _byKey.putIfAbsent(
          key,
          () => kPetCollisionBuiltInDefaultFor(
            speciesCode: species,
            stage: stage,
          ),
        );
      }
    }
  }

  PetCollisionTuneConfig forPet({
    required String speciesCode,
    required String stage,
  }) {
    final key = petCollisionTuneKey(speciesCode: speciesCode, stage: stage);
    return _byKey.putIfAbsent(
      key,
      () => kPetCollisionBuiltInDefaultFor(
        speciesCode: speciesCode,
        stage: stage,
      ),
    );
  }

  void applyAll(PetCollisionTuneStore other) {
    for (final entry in other._byKey.entries) {
      _byKey
          .putIfAbsent(entry.key, () => entry.value.clone())
          .copyFrom(entry.value);
    }
    ensureAllSlots();
  }

  void resetSlot({
    required String speciesCode,
    required String stage,
  }) {
    forPet(speciesCode: speciesCode, stage: stage).resetToDefaultFor(
      speciesCode: speciesCode,
      stage: stage,
    );
  }

  void resetAllToDefaults() {
    ensureAllSlots();
    for (final species in kPetCollisionSpeciesCodes) {
      for (final stage in kPetCollisionStageFolders) {
        resetSlot(speciesCode: species, stage: stage);
      }
    }
  }
}

/// SharedPreferences 저장/복원.
class PetCollisionTunePreferences {
  /// v2: 표 기준 종×단계 기본값. 구 v1 저장값은 무시하고 새 기본값으로 시드.
  static const String keyMapJson = 'debug_pet_collision_tune_map_v2';

  static Future<PetCollisionTuneStore> load() async {
    final store = PetCollisionTuneStore();
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
        if (parts.length != 2) continue;
        final speciesCode = parts[0];
        final stage = parts[1];
        store._byKey[key] = PetCollisionTuneConfig.fromJson(
          Map<String, dynamic>.from(value),
          speciesCode: speciesCode,
          stage: stage,
        );
      }
      store.ensureAllSlots();
    } catch (e) {
      debugPrint('PetCollisionTunePreferences.load failed: $e');
      store.resetAllToDefaults();
    }
    return store;
  }

  static Future<void> save(PetCollisionTuneStore store) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      store.ensureAllSlots();
      final map = <String, dynamic>{};
      for (final entry in store._byKey.entries) {
        map[entry.key] = entry.value.toJson();
      }
      await prefs.setString(keyMapJson, jsonEncode(map));
    } catch (e) {
      debugPrint('PetCollisionTunePreferences.save failed: $e');
    }
  }
}
