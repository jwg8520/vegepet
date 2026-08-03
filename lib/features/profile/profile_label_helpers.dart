import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vegepet/features/pet/vegepet_species_identity.dart';
import 'package:vegepet/l10n/app_localizations.dart';
import 'package:vegepet/ui/vegepet_glass.dart';

/// 현재 적용된 앱 locale 이 영어인지 확인. fontSize/창 높이/문구 분기에 사용한다.
bool isEnglishLocale(BuildContext context) {
  return Localizations.localeOf(context).languageCode == 'en';
}

double gameMenuSubPanelTitleTop(BuildContext context) {
  return kVegePetGameMenuSubPanelTitleTop +
      (isEnglishLocale(context)
          ? kVegePetGameMenuSubPanelTitleTopEnOffset
          : 0.0);
}

/// DB 체중 값 → 입력창 표시용 문자열. 불필요한 Trailing `.0` 을 제거한다.
String formatWeightKgForInput(dynamic value) {
  if (value == null) return '';

  final parsed = double.tryParse(value.toString());
  if (parsed == null) return '';
  if (!parsed.isFinite) return '';

  if (parsed == parsed.roundToDouble()) {
    return parsed.toInt().toString();
  }

  return parsed
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// 남은 체중(차이) 표시용. 부동소수점 오차를 0으로 정규화한다.
String formatWeightDifferenceKg(double value) {
  final normalized = value.abs() < 0.001 ? 0.0 : value;
  return formatWeightKgForInput(normalized);
}

/// 현재 체중 ≤ 목표 체중 이면 목표 달성.
bool isWeightGoalAchieved({
  required double? currentWeightKg,
  required double? targetWeightKg,
}) {
  if (currentWeightKg == null || targetWeightKg == null) return false;
  if (!currentWeightKg.isFinite || !targetWeightKg.isFinite) return false;

  var difference = currentWeightKg - targetWeightKg;
  if (difference.abs() < 0.001) difference = 0.0;
  return difference <= 0;
}

/// 현재 체중 − 목표 체중. 계산 불가면 displayValue=null.
/// remaining ≤ 0 이면 goalAchieved=true.
({bool goalAchieved, String? displayValue}) computeRemainingWeightDisplay({
  required double? currentWeightKg,
  required double? targetWeightKg,
}) {
  if (currentWeightKg == null || targetWeightKg == null) {
    return (goalAchieved: false, displayValue: null);
  }
  if (!currentWeightKg.isFinite || !targetWeightKg.isFinite) {
    return (goalAchieved: false, displayValue: null);
  }

  var remaining = currentWeightKg - targetWeightKg;
  if (remaining.abs() < 0.001) remaining = 0.0;
  if (remaining <= 0) {
    return (goalAchieved: true, displayValue: null);
  }
  return (
    goalAchieved: false,
    displayValue: formatWeightDifferenceKg(remaining),
  );
}

/// 목표/현재 체중 입력용. `0-9`, 소수점 1회, 전체 최대 6자, `.5` 형태 거부.
/// 빈 문자열(전체 삭제)은 반드시 허용한다.
class WeightKgInputFormatter extends TextInputFormatter {
  static final RegExp _allowed = RegExp(r'^\d{0,3}(\.\d{0,2})?$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    // 1자리 → 공백(전체 삭제)도 허용해야 placeholder가 다시 보인다.
    if (text.isEmpty) return newValue;
    if (text.length > 6) return oldValue;
    if (text.startsWith('.')) return oldValue;
    if (text == '.') return oldValue;
    if (!_allowed.hasMatch(text)) return oldValue;
    return newValue;
  }
}

/// DB/내부 raw 값 → 화면 표시용. 저장·AI context에는 raw 를 그대로 쓴다.
String localizedGenderValue(String? raw, {required bool isEnglishLocale}) {
  final value = raw?.trim() ?? '';
  if (!isEnglishLocale) return value;

  switch (value) {
    case '여자':
      return 'Female';
    case '남자':
      return 'Male';
    default:
      return value;
  }
}

String localizedAgeRangeValue(String? raw, {required bool isEnglishLocale}) {
  final value = raw?.trim() ?? '';
  if (!isEnglishLocale) return value;

  switch (value) {
    case '10대':
      return 'Teens';
    case '20대':
      return '20s';
    case '30대':
      return '30s';
    case '40대':
      return '40s';
    case '50대':
      return '50s';
    default:
      return value;
  }
}

String localizedDietGoalValue(String? raw, {required bool isEnglishLocale}) {
  final value = raw?.trim() ?? '';
  if (!isEnglishLocale) return value;

  switch (value) {
    case '다이어트':
      return 'Weight Loss';
    case '근력향상':
      return 'Muscle Gain';
    case '혈당조정':
      return 'Blood Sugar Control';
    default:
      return value;
  }
}

/// pet_species row 기반 종류명 표시. 정보창 Type·도감 종 이름에 사용.
String localizedPetSpeciesNameFromRaw({
  required String? nameKo,
  String? nameEn,
  String? family,
  String? code,
  int? id,
  required bool isEnglishLocale,
}) {
  return speciesDisplayNameForLocale({
    'id': ?id,
    'name_ko': nameKo,
    'name_en': nameEn,
    'family': family,
    'code': code,
  }, isEnglishLocale: isEnglishLocale);
}

/// 메뉴 라벨 key → 현재 locale 표시 문자열.
String menuLabelForKey(String key, AppLocalizations l10n) {
  switch (key) {
    case 'profile':
      return l10n.menuLabelProfile;
    case 'dietDiary':
      return l10n.menuLabelDietDiary;
    case 'analysis':
      return l10n.menuAnalysis;
    case 'bag':
      return l10n.menuLabelBag;
    case 'pokedex':
      return l10n.menuLabelPokedex;
    case 'story':
      return l10n.menuLabelStory;
    case 'help':
      return l10n.menuLabelHelp;
    case 'settings':
      return l10n.menuLabelSettings;
    default:
      return key;
  }
}
