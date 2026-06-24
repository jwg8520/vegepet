import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 펫 그림자 기본 색상 (불투명 RGB). 적용 시 [PetShadowTuneConfig.opacity] 와 곱한다.
const Color kPetShadowDefaultColor = Color(0xFF527A7B);

/// 펫 그림자 debug/런타임 튜닝 설정.
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
}

const bool kPetShadowDefaultEnabled = true;
const double kPetShadowDefaultOpacity = 0.47;
const double kPetShadowDefaultOffsetX = 2.9;
const double kPetShadowDefaultOffsetY = -9.5;
const double kPetShadowDefaultWidthScale = 0.70;
const double kPetShadowDefaultHeightScale = 0.19;
const double kPetShadowDefaultBlurSigma = 0.6;

/// debug 펫 그림자 튜닝 값 SharedPreferences 저장/복원.
class PetShadowTunePreferences {
  static const String keyEnabled = 'debug_pet_shadow_enabled';
  static const String keyColorHex = 'debug_pet_shadow_color_hex';
  static const String keyOpacity = 'debug_pet_shadow_opacity';
  static const String keyOffsetX = 'debug_pet_shadow_offset_x';
  static const String keyOffsetY = 'debug_pet_shadow_offset_y';
  static const String keyWidthScale = 'debug_pet_shadow_width_scale';
  static const String keyHeightScale = 'debug_pet_shadow_height_scale';
  static const String keyBlurSigma = 'debug_pet_shadow_blur_sigma';

  static Future<PetShadowTuneConfig> load() async {
    final config = PetShadowTuneConfig();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey(keyEnabled)) {
        return config;
      }
      config.enabled = prefs.getBool(keyEnabled) ?? kPetShadowDefaultEnabled;
      final hex = prefs.getString(keyColorHex);
      if (hex != null && hex.isNotEmpty) {
        final parsed = _parseHexColor(hex);
        if (parsed != null) config.color = parsed;
      }
      config.opacity = prefs.getDouble(keyOpacity) ?? kPetShadowDefaultOpacity;
      config.offsetX = prefs.getDouble(keyOffsetX) ?? kPetShadowDefaultOffsetX;
      config.offsetY = prefs.getDouble(keyOffsetY) ?? kPetShadowDefaultOffsetY;
      config.widthScale =
          prefs.getDouble(keyWidthScale) ?? kPetShadowDefaultWidthScale;
      config.heightScale =
          prefs.getDouble(keyHeightScale) ?? kPetShadowDefaultHeightScale;
      config.blurSigma =
          prefs.getDouble(keyBlurSigma) ?? kPetShadowDefaultBlurSigma;
    } catch (e) {
      debugPrint('PetShadowTunePreferences.load failed: $e');
      config.resetToDefaults();
    }
    return config;
  }

  static Future<void> save(PetShadowTuneConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(keyEnabled, config.enabled);
      await prefs.setString(keyColorHex, colorToHex(config.color));
      await prefs.setDouble(keyOpacity, config.opacity);
      await prefs.setDouble(keyOffsetX, config.offsetX);
      await prefs.setDouble(keyOffsetY, config.offsetY);
      await prefs.setDouble(keyWidthScale, config.widthScale);
      await prefs.setDouble(keyHeightScale, config.heightScale);
      await prefs.setDouble(keyBlurSigma, config.blurSigma);
    } catch (e) {
      debugPrint('PetShadowTunePreferences.save failed: $e');
    }
  }

  static String colorToHex(Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return rgb.toRadixString(16).padLeft(6, '0').toUpperCase();
  }

  static Color? _parseHexColor(String input) {
    var hex = input.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 6) {
      final value = int.tryParse(hex, radix: 16);
      if (value != null) return Color(0xFF000000 | value);
    }
    return null;
  }
}
