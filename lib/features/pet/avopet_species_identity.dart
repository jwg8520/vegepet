/// AvoPet 종족 표시명·내부 코드명 매핑.
///
/// - DB/에셋/내부 코드(`cat_sco` 등)는 유지한다.
/// - UI 표시명만 앱에서 override 한다.
/// - 전체 6종 구조는 유지하되, MVP에서는 [availableInMvp] == true 인 4종만 사용한다.
/// - DB `id` 가 재배치되어도 `code` 를 우선해 식별한다.
class AvoPetSpeciesIdentity {
  const AvoPetSpeciesIdentity({
    required this.id,
    required this.family,
    required this.nameKo,
    required this.nameEn,
    required this.internalCode,
    required this.availableInMvp,
  });

  final int id;
  final String family; // cat | dog
  final String nameKo;
  final String nameEn;
  final String internalCode;

  /// false 인 종(코리/푸리)은 구조만 유지하고 MVP 선택·도감·랜덤 분양에서 제외.
  final bool availableInMvp;
}

const _species1 = AvoPetSpeciesIdentity(
  id: 1,
  family: 'cat',
  nameKo: '스코티쉬 폴드',
  nameEn: 'Fold',
  internalCode: 'cat_sco',
  availableInMvp: true,
);
const _species2 = AvoPetSpeciesIdentity(
  id: 2,
  family: 'cat',
  nameKo: '랙돌',
  nameEn: 'Raggie',
  internalCode: 'cat_rag',
  availableInMvp: true,
);
const _species3 = AvoPetSpeciesIdentity(
  id: 3,
  family: 'cat',
  nameKo: '코리',
  nameEn: 'Kori',
  internalCode: 'cat_kor',
  availableInMvp: false,
);
const _species4 = AvoPetSpeciesIdentity(
  id: 4,
  family: 'dog',
  nameKo: '포메라니안',
  nameEn: 'Pom',
  internalCode: 'dog_pom',
  availableInMvp: true,
);
const _species5 = AvoPetSpeciesIdentity(
  id: 5,
  family: 'dog',
  nameKo: '비숑',
  nameEn: 'Bichon',
  internalCode: 'dog_bic',
  availableInMvp: true,
);
const _species6 = AvoPetSpeciesIdentity(
  id: 6,
  family: 'dog',
  nameKo: '푸리',
  nameEn: 'Puri',
  internalCode: 'dog_pud',
  availableInMvp: false,
);

const Map<int, AvoPetSpeciesIdentity> kSpeciesIdentityById = {
  1: _species1,
  2: _species2,
  3: _species3,
  4: _species4,
  5: _species5,
  6: _species6,
};

/// MVP 분양·도감·랜덤 분양에 사용하는 내부 코드 (푸리/코리 제외).
const Set<String> kMvpSpeciesInternalCodes = {
  'cat_sco',
  'cat_rag',
  'dog_pom',
  'dog_bic',
};

/// 레거시 id 집합 (DB id 가 1/2/4/5 인 기존 시드용). code 우선 판정이 더 안전하다.
const Set<int> kMvpSpeciesIds = {1, 2, 4, 5};

/// MVP에서 제외하는 내부 코드 (향후 재추가 가능하도록 구조만 유지).
const Set<String> kNonMvpSpeciesInternalCodes = {'cat_kor', 'dog_pud'};

const Map<String, AvoPetSpeciesIdentity> kSpeciesIdentityByOldName = {
  // 정식/현재 표시명 (한국어)
  '스코티쉬 폴드': _species1,
  '랙돌': _species2,
  '코리안 숏헤어': _species3,
  '포메라니안': _species4,
  '비숑': _species5,
  '푸들': _species6,
  // 정식/현재 표시명 (영어)
  'Scottish Fold': _species1,
  'Fold': _species1,
  'Ragdoll': _species2,
  'Raggie': _species2,
  'Korean Shorthair': _species3,
  'Pomeranian': _species4,
  'Pom': _species4,
  'Bichon': _species5,
  'Poodle': _species6,
  // 이전 짧은 표시명 (DB/캐시 호환)
  '스코': _species1,
  'Sco': _species1,
  '돌리': _species2,
  'Dolly': _species2,
  '코리': _species3,
  'Kori': _species3,
  '포미': _species4,
  'Pomi': _species4,
  '비비': _species5,
  'Bibi': _species5,
  '푸리': _species6,
  'Puri': _species6,
  // 내부 코드명
  'cat_sco': _species1,
  'cat_rag': _species2,
  'cat_kor': _species3,
  'dog_pom': _species4,
  'dog_bic': _species5,
  'dog_pud': _species6,
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
  if (kNonMvpSpeciesInternalCodes.contains(normalized)) return false;
  return kMvpSpeciesInternalCodes.contains(normalized);
}

bool isMvpSpeciesRow(Map<String, dynamic>? species) {
  if (species == null) return false;

  final code = species['code']?.toString().trim().toLowerCase() ?? '';
  if (code.isNotEmpty) {
    if (kNonMvpSpeciesInternalCodes.contains(code)) return false;
    if (kMvpSpeciesInternalCodes.contains(code)) return true;
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
