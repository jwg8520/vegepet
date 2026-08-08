import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 쓰다듬기 하트 이펙트 기본 색상 (불투명 RGB). 적용 시 [PettingHeartTuneConfig.opacity] 와 곱한다.
const Color kPettingHeartDefaultColor = Color(0xFFEF5592);

/// 쓰다듬기 하트 이펙트 debug/런타임 튜닝 설정.
class PettingHeartTuneConfig {
  PettingHeartTuneConfig({
    this.enabled = kPettingHeartDefaultEnabled,
    Color? color,
    this.opacity = kPettingHeartDefaultOpacity,
    this.size = kPettingHeartDefaultSize,
    this.offsetX = kPettingHeartDefaultOffsetX,
    this.offsetY = kPettingHeartDefaultOffsetY,
    this.riseDistance = kPettingHeartDefaultRiseDistance,
    this.durationMs = kPettingHeartDefaultDurationMs,
    this.scaleStart = kPettingHeartDefaultScaleStart,
    this.scaleEnd = kPettingHeartDefaultScaleEnd,
    this.burstIntervalMs = kPettingHeartDefaultBurstIntervalMs,
  }) : color = color ?? kPettingHeartDefaultColor;

  bool enabled;
  Color color;
  double opacity;
  double size;
  double offsetX;
  double offsetY;
  double riseDistance;
  int durationMs;
  double scaleStart;
  double scaleEnd;

  /// 연속 하트(버스트) 사이 간격.
  int burstIntervalMs;

  double get durationSeconds =>
      (durationMs <= 0 ? kPettingHeartDefaultDurationMs : durationMs) / 1000.0;

  void resetToDefaults() {
    enabled = kPettingHeartDefaultEnabled;
    color = kPettingHeartDefaultColor;
    opacity = kPettingHeartDefaultOpacity;
    size = kPettingHeartDefaultSize;
    offsetX = kPettingHeartDefaultOffsetX;
    offsetY = kPettingHeartDefaultOffsetY;
    riseDistance = kPettingHeartDefaultRiseDistance;
    durationMs = kPettingHeartDefaultDurationMs;
    scaleStart = kPettingHeartDefaultScaleStart;
    scaleEnd = kPettingHeartDefaultScaleEnd;
    burstIntervalMs = kPettingHeartDefaultBurstIntervalMs;
  }

  void copyFrom(PettingHeartTuneConfig other) {
    enabled = other.enabled;
    color = other.color;
    opacity = other.opacity;
    size = other.size;
    offsetX = other.offsetX;
    offsetY = other.offsetY;
    riseDistance = other.riseDistance;
    durationMs = other.durationMs;
    scaleStart = other.scaleStart;
    scaleEnd = other.scaleEnd;
    burstIntervalMs = other.burstIntervalMs;
  }

  PettingHeartTuneConfig clone() {
    return PettingHeartTuneConfig(
      enabled: enabled,
      color: color,
      opacity: opacity,
      size: size,
      offsetX: offsetX,
      offsetY: offsetY,
      riseDistance: riseDistance,
      durationMs: durationMs,
      scaleStart: scaleStart,
      scaleEnd: scaleEnd,
      burstIntervalMs: burstIntervalMs,
    );
  }
}

const bool kPettingHeartDefaultEnabled = true;
const double kPettingHeartDefaultOpacity = 1.0;
const double kPettingHeartDefaultSize = 15.7;
const double kPettingHeartDefaultOffsetX = -0.7;
const double kPettingHeartDefaultOffsetY = 12.9;
const double kPettingHeartDefaultRiseDistance = 36.0;
const int kPettingHeartDefaultDurationMs = 2500;
const double kPettingHeartDefaultScaleStart = 0.85;
const double kPettingHeartDefaultScaleEnd = 1.13;
const int kPettingHeartDefaultBurstIntervalMs = 459;
const int kPettingHeartDefaultBurstCount = 3;

/// debug 쓰다듬기 하트 튜닝 값 SharedPreferences 저장/복원.
class PettingHeartTunePreferences {
  /// v2: 첨부 표 기준 기본값(oY 12.9, gap 459). 구 저장값은 무시하고 재시드.
  static const int schemaVersion = 2;
  static const String keySchemaVersion = 'debug_petting_heart_schema_v';
  static const String keyEnabled = 'debug_petting_heart_enabled';
  static const String keyColorHex = 'debug_petting_heart_color_hex';
  static const String keyOpacity = 'debug_petting_heart_opacity';
  static const String keySize = 'debug_petting_heart_size';
  static const String keyOffsetX = 'debug_petting_heart_offset_x';
  static const String keyOffsetY = 'debug_petting_heart_offset_y';
  static const String keyRiseDistance = 'debug_petting_heart_rise_distance';
  static const String keyDurationMs = 'debug_petting_heart_duration_ms';
  static const String keyScaleStart = 'debug_petting_heart_scale_start';
  static const String keyScaleEnd = 'debug_petting_heart_scale_end';
  static const String keyBurstIntervalMs =
      'debug_petting_heart_burst_interval_ms';

  static Future<PettingHeartTuneConfig> load() async {
    final config = PettingHeartTuneConfig();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(keySchemaVersion) != schemaVersion) {
        return config;
      }
      if (!prefs.containsKey(keyEnabled)) {
        return config;
      }
      config.enabled = prefs.getBool(keyEnabled) ?? kPettingHeartDefaultEnabled;
      final hex = prefs.getString(keyColorHex);
      if (hex != null && hex.isNotEmpty) {
        final parsed = _parseHexColor(hex);
        if (parsed != null) config.color = parsed;
      }
      config.opacity =
          prefs.getDouble(keyOpacity) ?? kPettingHeartDefaultOpacity;
      config.size = prefs.getDouble(keySize) ?? kPettingHeartDefaultSize;
      config.offsetX =
          prefs.getDouble(keyOffsetX) ?? kPettingHeartDefaultOffsetX;
      config.offsetY =
          prefs.getDouble(keyOffsetY) ?? kPettingHeartDefaultOffsetY;
      config.riseDistance =
          prefs.getDouble(keyRiseDistance) ?? kPettingHeartDefaultRiseDistance;
      config.durationMs =
          prefs.getInt(keyDurationMs) ?? kPettingHeartDefaultDurationMs;
      config.scaleStart =
          prefs.getDouble(keyScaleStart) ?? kPettingHeartDefaultScaleStart;
      config.scaleEnd =
          prefs.getDouble(keyScaleEnd) ?? kPettingHeartDefaultScaleEnd;
      config.burstIntervalMs =
          prefs.getInt(keyBurstIntervalMs) ??
          kPettingHeartDefaultBurstIntervalMs;
    } catch (e) {
      debugPrint('PettingHeartTunePreferences.load failed: $e');
      config.resetToDefaults();
    }
    return config;
  }

  static Future<void> save(PettingHeartTuneConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(keySchemaVersion, schemaVersion);
      await prefs.setBool(keyEnabled, config.enabled);
      await prefs.setString(keyColorHex, colorToHex(config.color));
      await prefs.setDouble(keyOpacity, config.opacity);
      await prefs.setDouble(keySize, config.size);
      await prefs.setDouble(keyOffsetX, config.offsetX);
      await prefs.setDouble(keyOffsetY, config.offsetY);
      await prefs.setDouble(keyRiseDistance, config.riseDistance);
      await prefs.setInt(keyDurationMs, config.durationMs);
      await prefs.setDouble(keyScaleStart, config.scaleStart);
      await prefs.setDouble(keyScaleEnd, config.scaleEnd);
      await prefs.setInt(keyBurstIntervalMs, config.burstIntervalMs);
    } catch (e) {
      debugPrint('PettingHeartTunePreferences.save failed: $e');
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
