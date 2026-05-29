import 'package:flutter/material.dart';
import 'package:vegepet/l10n/app_localizations.dart';
import 'package:vegepet/ui/vegepet_glass.dart';

/// 현재 적용된 앱 locale 이 영어인지 확인. fontSize/창 높이/문구 분기에 사용한다.
bool isEnglishLocale(BuildContext context) {
  return Localizations.localeOf(context).languageCode == 'en';
}

double gameMenuSubPanelTitleTop(BuildContext context) {
  return kVegePetGameMenuSubPanelTitleTop +
      (isEnglishLocale(context) ? kVegePetGameMenuSubPanelTitleTopEnOffset : 0.0);
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

/// pet_species.name_ko 기반 종류명 표시. 정보창 Type·도감 종 이름에 사용.
String localizedPetSpeciesNameFromRaw({
  required String? nameKo,
  String? family,
  String? code,
  required bool isEnglishLocale,
}) {
  final rawName = nameKo?.trim() ?? '';
  if (!isEnglishLocale) return rawName;

  final lowerFamily = family?.trim().toLowerCase() ?? '';
  final lowerCode = code?.trim().toLowerCase() ?? '';

  int? number;
  final numberMatch = RegExp(r'(\d+)$').firstMatch(rawName);
  if (numberMatch != null) {
    number = int.tryParse(numberMatch.group(1)!);
  }

  String familyLabel;
  if (rawName.contains('고양이') ||
      rawName.contains('냥') ||
      lowerFamily == 'cat' ||
      lowerCode.contains('cat')) {
    familyLabel = 'Cat';
  } else if (rawName.contains('강아지') ||
      rawName.contains('댕') ||
      lowerFamily == 'dog' ||
      lowerCode.contains('dog')) {
    familyLabel = 'Dog';
  } else {
    familyLabel = 'VegePet';
  }

  if (number != null) {
    return '$familyLabel $number';
  }

  if (rawName.isNotEmpty) {
    return familyLabel == 'VegePet' ? rawName : familyLabel;
  }

  return familyLabel;
}

/// 메뉴 라벨 key → 현재 locale 표시 문자열.
String menuLabelForKey(String key, AppLocalizations l10n) {
  switch (key) {
    case 'profile':
      return l10n.menuLabelProfile;
    case 'dietDiary':
      return l10n.menuLabelDietDiary;
    case 'bag':
      return l10n.menuLabelBag;
    case 'shop':
      return l10n.menuLabelShop;
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
