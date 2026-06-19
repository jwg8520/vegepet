/// VegePet 6종 표시명·내부 코드명 매핑.
/// DB가 아직 기존 품종명을 반환해도 앱 표시는 새 이름으로 override 한다.
class VegePetSpeciesIdentity {
  const VegePetSpeciesIdentity({
    required this.id,
    required this.family,
    required this.nameKo,
    required this.nameEn,
    required this.internalCode,
  });

  final int id;
  final String family; // cat | dog
  final String nameKo;
  final String nameEn;
  final String internalCode;
}

const _species1 = VegePetSpeciesIdentity(
  id: 1,
  family: 'cat',
  nameKo: '스코',
  nameEn: 'Sco',
  internalCode: 'cat_sco',
);
const _species2 = VegePetSpeciesIdentity(
  id: 2,
  family: 'cat',
  nameKo: '돌리',
  nameEn: 'Dolly',
  internalCode: 'cat_rag',
);
const _species3 = VegePetSpeciesIdentity(
  id: 3,
  family: 'cat',
  nameKo: '코리',
  nameEn: 'Kori',
  internalCode: 'cat_kor',
);
const _species4 = VegePetSpeciesIdentity(
  id: 4,
  family: 'dog',
  nameKo: '포미',
  nameEn: 'Pomi',
  internalCode: 'dog_pom',
);
const _species5 = VegePetSpeciesIdentity(
  id: 5,
  family: 'dog',
  nameKo: '비비',
  nameEn: 'Bibi',
  internalCode: 'dog_bic',
);
const _species6 = VegePetSpeciesIdentity(
  id: 6,
  family: 'dog',
  nameKo: '푸리',
  nameEn: 'Puri',
  internalCode: 'dog_pud',
);

const Map<int, VegePetSpeciesIdentity> kSpeciesIdentityById = {
  1: _species1,
  2: _species2,
  3: _species3,
  4: _species4,
  5: _species5,
  6: _species6,
};

const Map<String, VegePetSpeciesIdentity> kSpeciesIdentityByOldName = {
  // 기존 DB 품종명 (한국어)
  '스코티쉬 폴드': _species1,
  '랙돌': _species2,
  '코리안 숏헤어': _species3,
  '포메라니안': _species4,
  '비숑': _species5,
  '푸들': _species6,
  // 기존 DB 품종명 (영어)
  'Scottish Fold': _species1,
  'Ragdoll': _species2,
  'Korean Shorthair': _species3,
  'Pomeranian': _species4,
  'Bichon': _species5,
  'Poodle': _species6,
  // 새 표시명 (DB 갱신 후에도 동일하게 매칭)
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

VegePetSpeciesIdentity? _identityFromNameKey(String? raw) {
  final key = raw?.trim();
  if (key == null || key.isEmpty) return null;
  return kSpeciesIdentityByOldName[key];
}

VegePetSpeciesIdentity? speciesIdentityFromSpeciesRow(
  Map<String, dynamic>? species,
) {
  if (species == null) return null;

  final id = _speciesIdFromRow(species);
  if (id != null) {
    final byId = kSpeciesIdentityById[id];
    if (byId != null) return byId;
  }

  final byNameKo = _identityFromNameKey(species['name_ko']?.toString());
  if (byNameKo != null) return byNameKo;

  final byNameEn = _identityFromNameKey(species['name_en']?.toString());
  if (byNameEn != null) return byNameEn;

  final code = species['code']?.toString().trim();
  if (code != null && code.isNotEmpty) {
    final byCode = kSpeciesIdentityByOldName[code] ??
        kSpeciesIdentityByOldName[code.toLowerCase()];
    if (byCode != null) return byCode;
  }

  return null;
}

String speciesDisplayNameKo(
  Map<String, dynamic>? species, {
  String fallback = '베지펫',
}) {
  final identity = speciesIdentityFromSpeciesRow(species);
  if (identity != null) return identity.nameKo;

  final nameKo = species?['name_ko']?.toString().trim();
  if (nameKo != null && nameKo.isNotEmpty) return nameKo;
  return fallback;
}

String speciesDisplayNameEn(
  Map<String, dynamic>? species, {
  String fallback = 'VegePet',
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
  String fallbackKo = '베지펫',
  String fallbackEn = 'VegePet',
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
