import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vegepet/game/pet_sprite_assets.dart';

/// 펫 그림자 기본 색상 (불투명 RGB). 적용 시 [PetShadowTuneConfig.opacity] 와 곱한다.
const Color kPetShadowDefaultColor = Color(0xFF527A7B);

const bool kPetShadowDefaultEnabled = true;
const double kPetShadowDefaultOpacity = 0.68;
const double kPetShadowDefaultOffsetX = 4.0;
const double kPetShadowDefaultOffsetY = -10.1;
const double kPetShadowDefaultWidthScale = 0.74;
const double kPetShadowDefaultHeightScale = 0.16;
const double kPetShadowDefaultBlurSigma = 0.5;

/// 그림자 튜닝 대상 종.
const List<String> kPetShadowSpeciesCodes = [
  'cat_rag',
  'cat_sco',
  'dog_bic',
  'dog_pom',
];

/// 그림자 튜닝 대상 단계 폴더 (adult 는 teen 과 동일 슬롯).
const List<String> kPetShadowStageFolders = [
  'baby',
  'young',
  'teen',
];

/// species + stage → prefs/map 키. adult 는 teen 폴더로 정규화.
String petShadowTuneKey({
  required String speciesCode,
  required String stage,
}) {
  final folder = petStageAssetFolder(stage);
  return '$speciesCode|$folder';
}

/// 펫 그림자 debug/런타임 튜닝 설정 (한 슬롯).
class PetShadowTuneConfig {
  PetShadowTuneConfig({
    this.enabled = kPetShadowDefaultEnabled,
    Color? color,
    this.opacity = kPetShadowDefaultOpacity,
    this.offsetX = kPetShadowDefaultOffsetX,
    this.offsetY = kPetShadowDefaultOffsetY,
    this.widthScale = kPetShadowDefaultWidthScale,
    this.heightScale = kPetShadowDefaultHeightScale,
    this.blurSigma = kPetShadowDefaultBlurSigma,
  }) : color = color ?? kPetShadowDefaultColor;

  bool enabled;
  Color color;
  double opacity;
  double offsetX;
  double offsetY;
  double widthScale;
  double heightScale;
  double blurSigma;

  /// Paint 에 바로 쓸 수 있는 색 (color × opacity).
  Color get paintColor => color.withValues(alpha: opacity);

  void resetToDefaults() {
    enabled = kPetShadowDefaultEnabled;
    color = kPetShadowDefaultColor;
    opacity = kPetShadowDefaultOpacity;
    offsetX = kPetShadowDefaultOffsetX;
    offsetY = kPetShadowDefaultOffsetY;
    widthScale = kPetShadowDefaultWidthScale;
    heightScale = kPetShadowDefaultHeightScale;
    blurSigma = kPetShadowDefaultBlurSigma;
  }

  void copyFrom(PetShadowTuneConfig other) {
    enabled = other.enabled;
    color = other.color;
    opacity = other.opacity;
    offsetX = other.offsetX;
    offsetY = other.offsetY;
    widthScale = other.widthScale;
    heightScale = other.heightScale;
    blurSigma = other.blurSigma;
  }

  PetShadowTuneConfig clone() {
    return PetShadowTuneConfig(
      enabled: enabled,
      color: color,
      opacity: opacity,
      offsetX: offsetX,
      offsetY: offsetY,
      widthScale: widthScale,
      heightScale: heightScale,
      blurSigma: blurSigma,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'colorHex': PetShadowTunePreferences.colorToHex(color),
      'opacity': opacity,
      'offsetX': offsetX,
      'offsetY': offsetY,
      'widthScale': widthScale,
      'heightScale': heightScale,
      'blurSigma': blurSigma,
    };
  }

  factory PetShadowTuneConfig.fromJson(Map<String, dynamic> json) {
    final config = PetShadowTuneConfig();
    config.enabled = json['enabled'] as bool? ?? kPetShadowDefaultEnabled;
    final hex = json['colorHex']?.toString();
    if (hex != null && hex.isNotEmpty) {
      final parsed = PetShadowTunePreferences.parseHexColor(hex);
      if (parsed != null) config.color = parsed;
    }
    config.opacity =
        (json['opacity'] as num?)?.toDouble() ?? kPetShadowDefaultOpacity;
    config.offsetX =
        (json['offsetX'] as num?)?.toDouble() ?? kPetShadowDefaultOffsetX;
    config.offsetY =
        (json['offsetY'] as num?)?.toDouble() ?? kPetShadowDefaultOffsetY;
    config.widthScale =
        (json['widthScale'] as num?)?.toDouble() ??
        kPetShadowDefaultWidthScale;
    config.heightScale =
        (json['heightScale'] as num?)?.toDouble() ??
        kPetShadowDefaultHeightScale;
    config.blurSigma =
        (json['blurSigma'] as num?)?.toDouble() ?? kPetShadowDefaultBlurSigma;
    return config;
  }
}

/// 종×단계별 그림자 튜닝 저장소.
class PetShadowTuneStore {
  PetShadowTuneStore() {
    ensureAllSlots();
  }

  final Map<String, PetShadowTuneConfig> _byKey = {};

  Map<String, PetShadowTuneConfig> get entries =>
      Map.unmodifiable(_byKey);

  void ensureAllSlots() {
    for (final species in kPetShadowSpeciesCodes) {
      for (final stage in kPetShadowStageFolders) {
        final key = petShadowTuneKey(speciesCode: species, stage: stage);
        _byKey.putIfAbsent(key, PetShadowTuneConfig.new);
      }
    }
  }

  PetShadowTuneConfig forPet({
    required String speciesCode,
    required String stage,
  }) {
    final key = petShadowTuneKey(speciesCode: speciesCode, stage: stage);
    return _byKey.putIfAbsent(key, PetShadowTuneConfig.new);
  }

  void applyAll(PetShadowTuneStore other) {
    for (final entry in other._byKey.entries) {
      _byKey.putIfAbsent(entry.key, PetShadowTuneConfig.new).copyFrom(entry.value);
    }
    ensureAllSlots();
  }

  void fillAllFrom(PetShadowTuneConfig template) {
    ensureAllSlots();
    for (final config in _byKey.values) {
      config.copyFrom(template);
    }
  }

  void resetSlot({
    required String speciesCode,
    required String stage,
  }) {
    forPet(speciesCode: speciesCode, stage: stage).resetToDefaults();
  }

  void resetAllToDefaults() {
    ensureAllSlots();
    for (final config in _byKey.values) {
      config.resetToDefaults();
    }
  }
}

/// debug 펫 그림자 튜닝 값 SharedPreferences 저장/복원 (종×단계 맵).
class PetShadowTunePreferences {
  static const String keyMapJson = 'debug_pet_shadow_tune_map_v1';

  // 구버전 단일 슬롯 키 (마이그레이션용).
  static const String keyEnabled = 'debug_pet_shadow_enabled';
  static const String keyColorHex = 'debug_pet_shadow_color_hex';
  static const String keyOpacity = 'debug_pet_shadow_opacity';
  static const String keyOffsetX = 'debug_pet_shadow_offset_x';
  static const String keyOffsetY = 'debug_pet_shadow_offset_y';
  static const String keyWidthScale = 'debug_pet_shadow_width_scale';
  static const String keyHeightScale = 'debug_pet_shadow_height_scale';
  static const String keyBlurSigma = 'debug_pet_shadow_blur_sigma';

  static Future<PetShadowTuneStore> load() async {
    final store = PetShadowTuneStore();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyMapJson);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key.toString();
            final value = entry.value;
            if (value is Map) {
              store._byKey[key] = PetShadowTuneConfig.fromJson(
                Map<String, dynamic>.from(value),
              );
            }
          }
        }
        store.ensureAllSlots();
        return store;
      }

      // 구버전 단일 설정이 있으면 모든 슬롯에 복제.
      if (prefs.containsKey(keyEnabled)) {
        final legacy = PetShadowTuneConfig();
        legacy.enabled = prefs.getBool(keyEnabled) ?? kPetShadowDefaultEnabled;
        final hex = prefs.getString(keyColorHex);
        if (hex != null && hex.isNotEmpty) {
          final parsed = parseHexColor(hex);
          if (parsed != null) legacy.color = parsed;
        }
        legacy.opacity =
            prefs.getDouble(keyOpacity) ?? kPetShadowDefaultOpacity;
        legacy.offsetX =
            prefs.getDouble(keyOffsetX) ?? kPetShadowDefaultOffsetX;
        legacy.offsetY =
            prefs.getDouble(keyOffsetY) ?? kPetShadowDefaultOffsetY;
        legacy.widthScale =
            prefs.getDouble(keyWidthScale) ?? kPetShadowDefaultWidthScale;
        legacy.heightScale =
            prefs.getDouble(keyHeightScale) ?? kPetShadowDefaultHeightScale;
        legacy.blurSigma =
            prefs.getDouble(keyBlurSigma) ?? kPetShadowDefaultBlurSigma;
        store.fillAllFrom(legacy);
      }
    } catch (e) {
      debugPrint('PetShadowTunePreferences.load failed: $e');
      store.resetAllToDefaults();
    }
    return store;
  }

  static Future<void> save(PetShadowTuneStore store) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      store.ensureAllSlots();
      final map = <String, dynamic>{};
      for (final entry in store._byKey.entries) {
        map[entry.key] = entry.value.toJson();
      }
      await prefs.setString(keyMapJson, jsonEncode(map));
    } catch (e) {
      debugPrint('PetShadowTunePreferences.save failed: $e');
    }
  }

  /// 하위 호환: 예전 API 가 단일 config 를 기대할 때 사용하지 않음.
  @Deprecated('Use load() → PetShadowTuneStore')
  static Future<PetShadowTuneConfig> loadLegacySingle() async {
    final store = await load();
    return store.forPet(speciesCode: 'cat_sco', stage: 'baby').clone();
  }

  static String colorToHex(Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return rgb.toRadixString(16).padLeft(6, '0').toUpperCase();
  }

  static Color? parseHexColor(String input) {
    var hex = input.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      if (value != null) return Color(0xFF000000 | value);
    }
    return null;
  }
}
