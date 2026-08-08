import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vegepet/game/pet_sprite_assets.dart';

/// 펫 그림자 기본 색상 (불투명 RGB). 적용 시 [PetShadowTuneConfig.opacity] 와 곱한다.
const Color kPetShadowDefaultColor = Color(0xFF527A7B);

const bool kPetShadowDefaultEnabled = true;

/// 표에 없는 필드/폴백용 (enabled·color 공통).
const double kPetShadowDefaultOpacity = 0.56;
const double kPetShadowDefaultOffsetX = -0.4;
const double kPetShadowDefaultOffsetY = -13.4;
const double kPetShadowDefaultWidthScale = 0.56;
const double kPetShadowDefaultHeightScale = 0.17;
const double kPetShadowDefaultBlurSigma = 0.7;

/// debug 슬라이더와 동일한 scale 허용 범위.
const double kPetShadowWidthScaleMin = 0.2;
const double kPetShadowWidthScaleMax = 1.2;
const double kPetShadowHeightScaleMin = 0.05;
const double kPetShadowHeightScaleMax = 0.5;

double clampPetShadowWidthScale(double value) =>
    value.clamp(kPetShadowWidthScaleMin, kPetShadowWidthScaleMax).toDouble();

double clampPetShadowHeightScale(double value) =>
    value.clamp(kPetShadowHeightScaleMin, kPetShadowHeightScaleMax).toDouble();

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

PetShadowTuneConfig _shadowSpec({
  required double opac,
  required double oX,
  required double oY,
  required double wSc,
  required double hSc,
  required double blur,
}) {
  return PetShadowTuneConfig(
    enabled: kPetShadowDefaultEnabled,
    color: kPetShadowDefaultColor,
    opacity: opac,
    offsetX: oX,
    offsetY: oY,
    widthScale: wSc,
    heightScale: hSc,
    blurSigma: blur,
  );
}

/// 표 기준 빌트인 기본값 (종×단계). 런타임 mutate 금지 — clone 해서 사용.
PetShadowTuneConfig kPetShadowBuiltInDefaultFor({
  required String speciesCode,
  required String stage,
}) {
  final folder = petStageAssetFolder(stage);
  switch (speciesCode) {
    case 'cat_sco':
      return switch (folder) {
        'young' => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -15.9,
          wSc: 0.61,
          hSc: 0.19,
          blur: 0.7,
        ),
        'teen' => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -19.4,
          wSc: 0.61,
          hSc: 0.21,
          blur: 0.7,
        ),
        'baby' || _ => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -13.4,
          wSc: 0.54,
          hSc: 0.19,
          blur: 0.7,
        ),
      };
    case 'cat_rag':
      return switch (folder) {
        'young' => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -15.9,
          wSc: 0.61,
          hSc: 0.19,
          blur: 0.7,
        ),
        'teen' => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -19.4,
          wSc: 0.61,
          hSc: 0.21,
          blur: 0.7,
        ),
        'baby' || _ => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -13.4,
          wSc: 0.56,
          hSc: 0.17,
          blur: 0.7,
        ),
      };
    case 'dog_bic':
      return switch (folder) {
        'young' => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -15.9,
          wSc: 0.56,
          hSc: 0.19,
          blur: 0.7,
        ),
        'teen' => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -19.4,
          wSc: 0.56,
          hSc: 0.21,
          blur: 0.7,
        ),
        'baby' || _ => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -13.4,
          wSc: 0.56,
          hSc: 0.17,
          blur: 0.7,
        ),
      };
    case 'dog_pom':
      return switch (folder) {
        'young' => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -15.9,
          wSc: 0.56,
          hSc: 0.19,
          blur: 0.7,
        ),
        'teen' => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -18.6,
          wSc: 0.56,
          hSc: 0.21,
          blur: 0.7,
        ),
        'baby' || _ => _shadowSpec(
          opac: 0.56,
          oX: -0.4,
          oY: -13.4,
          wSc: 0.56,
          hSc: 0.17,
          blur: 0.7,
        ),
      };
    default:
      return _shadowSpec(
        opac: kPetShadowDefaultOpacity,
        oX: kPetShadowDefaultOffsetX,
        oY: kPetShadowDefaultOffsetY,
        wSc: kPetShadowDefaultWidthScale,
        hSc: kPetShadowDefaultHeightScale,
        blur: kPetShadowDefaultBlurSigma,
      );
  }
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

  void clampScales() {
    widthScale = clampPetShadowWidthScale(widthScale);
    heightScale = clampPetShadowHeightScale(heightScale);
  }

  void resetToDefaults() {
    // 종·단계 미지정 폴백 (cat_sco baby).
    copyFrom(
      kPetShadowBuiltInDefaultFor(speciesCode: 'cat_sco', stage: 'baby'),
    );
  }

  void resetToDefaultFor({
    required String speciesCode,
    required String stage,
  }) {
    copyFrom(
      kPetShadowBuiltInDefaultFor(speciesCode: speciesCode, stage: stage),
    );
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
    clampScales();
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

  factory PetShadowTuneConfig.fromJson(
    Map<String, dynamic> json, {
    String speciesCode = 'cat_sco',
    String stage = 'baby',
  }) {
    final d = kPetShadowBuiltInDefaultFor(
      speciesCode: speciesCode,
      stage: stage,
    );
    final config = PetShadowTuneConfig(
      enabled: json['enabled'] as bool? ?? d.enabled,
      color: d.color,
      opacity: (json['opacity'] as num?)?.toDouble() ?? d.opacity,
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? d.offsetX,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? d.offsetY,
      widthScale: (json['widthScale'] as num?)?.toDouble() ?? d.widthScale,
      heightScale: (json['heightScale'] as num?)?.toDouble() ?? d.heightScale,
      blurSigma: (json['blurSigma'] as num?)?.toDouble() ?? d.blurSigma,
    );
    final hex = json['colorHex']?.toString();
    if (hex != null && hex.isNotEmpty) {
      final parsed = PetShadowTunePreferences.parseHexColor(hex);
      if (parsed != null) config.color = parsed;
    }
    config.clampScales();
    return config;
  }
}

/// 종×단계별 그림자 튜닝 저장소.
class PetShadowTuneStore {
  PetShadowTuneStore() {
    ensureAllSlots();
  }

  final Map<String, PetShadowTuneConfig> _byKey = {};

  Map<String, PetShadowTuneConfig> get entries => Map.unmodifiable(_byKey);

  void ensureAllSlots() {
    for (final species in kPetShadowSpeciesCodes) {
      for (final stage in kPetShadowStageFolders) {
        final key = petShadowTuneKey(speciesCode: species, stage: stage);
        _byKey.putIfAbsent(
          key,
          () => kPetShadowBuiltInDefaultFor(
            speciesCode: species,
            stage: stage,
          ),
        );
      }
    }
  }

  PetShadowTuneConfig forPet({
    required String speciesCode,
    required String stage,
  }) {
    final key = petShadowTuneKey(speciesCode: speciesCode, stage: stage);
    return _byKey.putIfAbsent(
      key,
      () => kPetShadowBuiltInDefaultFor(
        speciesCode: speciesCode,
        stage: stage,
      ),
    );
  }

  void applyAll(PetShadowTuneStore other) {
    for (final entry in other._byKey.entries) {
      _byKey
          .putIfAbsent(entry.key, PetShadowTuneConfig.new)
          .copyFrom(entry.value);
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
    forPet(speciesCode: speciesCode, stage: stage).resetToDefaultFor(
      speciesCode: speciesCode,
      stage: stage,
    );
  }

  void resetAllToDefaults() {
    ensureAllSlots();
    for (final species in kPetShadowSpeciesCodes) {
      for (final stage in kPetShadowStageFolders) {
        resetSlot(speciesCode: species, stage: stage);
      }
    }
  }

  void clampAllScales() {
    ensureAllSlots();
    for (final config in _byKey.values) {
      config.clampScales();
    }
  }
}

/// debug 펫 그림자 튜닝 값 SharedPreferences 저장/복원 (종×단계 맵).
class PetShadowTunePreferences {
  /// v2: 표 기준 종×단계 기본값. 구 v1 저장값은 무시하고 새 기본값으로 시드.
  static const String keyMapJson = 'debug_pet_shadow_tune_map_v2';

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
              final parts = key.split('|');
              final species = parts.isNotEmpty ? parts[0] : 'cat_sco';
              final stage = parts.length > 1 ? parts[1] : 'baby';
              store._byKey[key] = PetShadowTuneConfig.fromJson(
                Map<String, dynamic>.from(value),
                speciesCode: species,
                stage: stage,
              );
            }
          }
        }
        store.ensureAllSlots();
        store.clampAllScales();
        return store;
      }

      // 구버전 단일 설정이 있으면 표 기본값 유지 (단일 값으로 덮지 않음).
    } catch (e) {
      debugPrint('PetShadowTunePreferences.load failed: $e');
      store.resetAllToDefaults();
    }
    store.clampAllScales();
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
