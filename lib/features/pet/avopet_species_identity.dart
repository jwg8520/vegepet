import 'package:flutter/foundation.dart';

/// AvoPet 종족 표시명·내부 코드명 매핑.
///
/// canonical Supabase `public.pet_species` (MVP 4종만):
/// - 1 → cat_sco (스코티쉬 폴드)
/// - 2 → cat_rag (랙돌)
/// - 3 → dog_pom (포메라니안)
/// - 4 → dog_bic (비숑)
///
/// - UI 표시명만 앱에서 override 한다.
/// - 식별은 **code 를 id 보다 우선**한다.
class AvoPetSpeciesIdentity {
  const AvoPetSpeciesIdentity({
    required this.id,
    required this.family,
    required this.nameKo,
    required this.nameEn,
    required this.internalCode,
    this.availableInMvp = true,
  });

  final int id;
  final String family; // cat | dog
  final String nameKo;
  final String nameEn;
  final String internalCode;

  /// 현재 canonical 4종은 모두 true. (하위 호환 필드)
  final bool availableInMvp;
}

const _speciesSco = AvoPetSpeciesIdentity(
  id: 1,
  family: 'cat',
  nameKo: '스코티쉬 폴드',
  nameEn: 'Fold',
  internalCode: 'cat_sco',
);
const _speciesRag = AvoPetSpeciesIdentity(
  id: 2,
  family: 'cat',
  nameKo: '랙돌',
  nameEn: 'Raggie',
  internalCode: 'cat_rag',
);
const _speciesPom = AvoPetSpeciesIdentity(
  id: 3,
  family: 'dog',
  nameKo: '포메라니안',
  nameEn: 'Pom',
  internalCode: 'dog_pom',
);
const _speciesBic = AvoPetSpeciesIdentity(
  id: 4,
  family: 'dog',
  nameKo: '비숑',
  nameEn: 'Bichon',
  internalCode: 'dog_bic',
);

/// Supabase pet_species.id → identity.
const Map<int, AvoPetSpeciesIdentity> kSpeciesIdentityById = {
  1: _speciesSco,
  2: _speciesRag,
  3: _speciesPom,
  4: _speciesBic,
};

/// MVP canonical 내부 코드 (source of truth).
const Set<String> kMvpSpeciesInternalCodes = {
  'cat_sco',
  'cat_rag',
  'dog_pom',
  'dog_bic',
};

/// MVP canonical pet_species.id (Supabase 와 동일).
const Set<int> kMvpSpeciesIds = {1, 2, 3, 4};

const Map<String, AvoPetSpeciesIdentity> kSpeciesIdentityByOldName = {
  // 정식/현재 표시명 (한국어)
  '스코티쉬 폴드': _speciesSco,
  '랙돌': _speciesRag,
  '포메라니안': _speciesPom,
  '비숑': _speciesBic,
  // 정식/현재 표시명 (영어)
  'Scottish Fold': _speciesSco,
  'Fold': _speciesSco,
  'Ragdoll': _speciesRag,
  'Raggie': _speciesRag,
  'Pomeranian': _speciesPom,
  'Pom': _speciesPom,
  'Bichon': _speciesBic,
  // 이전 짧은 표시명 (DB/캐시 호환)
  '스코': _speciesSco,
  'Sco': _speciesSco,
  '돌리': _speciesRag,
  'Dolly': _speciesRag,
  '포미': _speciesPom,
  'Pomi': _speciesPom,
  '비비': _speciesBic,
  'Bibi': _speciesBic,
  // 내부 코드명
  'cat_sco': _speciesSco,
  'cat_rag': _speciesRag,
  'dog_pom': _speciesPom,
  'dog_bic': _speciesBic,
};

int? _speciesIdFromRow(Map<String, dynamic> species) {
  final raw = species['id'];
  if (raw is int) return raw;
  return int.tryParse(raw?.toString() ?? '');
}

AvoPetSpeciesIdentity? _identityFromNameKey(String? raw) {
  final key = raw?.trim();
  if (key == null || key.isEmpty) return null;
  return kSpeciesIdentityByOldName[key];
}

AvoPetSpeciesIdentity? _identityFromCode(String? raw) {
  final code = raw?.trim();
  if (code == null || code.isEmpty) return null;
  return kSpeciesIdentityByOldName[code] ??
      kSpeciesIdentityByOldName[code.toLowerCase()];
}

/// DB row → identity. **code 를 id 보다 우선**해 id 재배치/시드 차이에 안전하다.
AvoPetSpeciesIdentity? speciesIdentityFromSpeciesRow(
  Map<String, dynamic>? species,
) {
  if (species == null) return null;

  final byCode = _identityFromCode(species['code']?.toString());
  if (byCode != null) return byCode;

  final byNameKo = _identityFromNameKey(species['name_ko']?.toString());
  if (byNameKo != null) return byNameKo;

  final byNameEn = _identityFromNameKey(species['name_en']?.toString());
  if (byNameEn != null) return byNameEn;

  final id = _speciesIdFromRow(species);
  if (id != null) {
    final byId = kSpeciesIdentityById[id];
    if (byId != null) return byId;
  }

  return null;
}

bool isMvpSpeciesId(int? speciesId) {
  if (speciesId == null) return false;
  return kMvpSpeciesIds.contains(speciesId);
}

bool isMvpSpeciesInternalCode(String? code) {
  final normalized = code?.trim().toLowerCase() ?? '';
  if (normalized.isEmpty) return false;
  return kMvpSpeciesInternalCodes.contains(normalized);
}

bool isMvpSpeciesRow(Map<String, dynamic>? species) {
  if (species == null) return false;

  final code = species['code']?.toString().trim().toLowerCase() ?? '';
  if (code.isNotEmpty) {
    return kMvpSpeciesInternalCodes.contains(code);
  }

  final identity = speciesIdentityFromSpeciesRow(species);
  if (identity != null) return identity.availableInMvp;

  final id = _speciesIdFromRow(species);
  return isMvpSpeciesId(id);
}

String speciesDisplayNameKo(
  Map<String, dynamic>? species, {
  String fallback = '아보펫',
}) {
  final identity = speciesIdentityFromSpeciesRow(species);
  if (identity != null) return identity.nameKo;

  final nameKo = species?['name_ko']?.toString().trim();
  if (nameKo != null && nameKo.isNotEmpty) return nameKo;
  return fallback;
}

String speciesDisplayNameEn(
  Map<String, dynamic>? species, {
  String fallback = 'AvoPet',
}) {
  final identity = speciesIdentityFromSpeciesRow(species);
  if (identity != null) return identity.nameEn;

  final nameEn = species?['name_en']?.toString().trim();
  if (nameEn != null && nameEn.isNotEmpty) return nameEn;

  final nameKo = species?['name_ko']?.toString().trim();
  if (nameKo != null && nameKo.isNotEmpty) return nameKo;
  return fallback;
}

String speciesDisplayNameForLocale(
  Map<String, dynamic>? species, {
  required bool isEnglishLocale,
  String fallbackKo = '아보펫',
  String fallbackEn = 'AvoPet',
}) {
  return isEnglishLocale
      ? speciesDisplayNameEn(species, fallback: fallbackEn)
      : speciesDisplayNameKo(species, fallback: fallbackKo);
}

String speciesInternalCode(Map<String, dynamic>? species) {
  final identity = speciesIdentityFromSpeciesRow(species);
  if (identity != null) return identity.internalCode;

  final code = species?['code']?.toString().trim();
  if (code != null && code.isNotEmpty) return code;
  return '';
}

/// debug: DB 로드 결과와 canonical id↔code 매핑이 어긋나면 경고한다.
void debugWarnIfPetSpeciesIdentityMismatch(
  List<Map<String, dynamic>> rows,
) {
  if (!kDebugMode) return;
  if (rows.isEmpty) return;

  const expected = <int, String>{
    1: 'cat_sco',
    2: 'cat_rag',
    3: 'dog_pom',
    4: 'dog_bic',
  };

  for (final row in rows) {
    final id = _speciesIdFromRow(row);
    final code = row['code']?.toString().trim().toLowerCase() ?? '';
    if (id == null || code.isEmpty) continue;
    final want = expected[id];
    if (want != null && want != code) {
      debugPrint(
        'pet_species identity mismatch: id=$id code=$code expected=$want',
      );
    }
    if (want == null && kMvpSpeciesInternalCodes.contains(code)) {
      debugPrint(
        'pet_species unexpected id for MVP code: id=$id code=$code '
        '(canonical ids are 1..4)',
      );
    }
  }
}
