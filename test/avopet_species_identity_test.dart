import 'package:avopet/features/pet/avopet_species_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('canonical MVP species identity', () {
    test('kMvpSpeciesIds is {1,2,3,4}', () {
      expect(kMvpSpeciesIds, {1, 2, 3, 4});
    });

    test('kMvpSpeciesInternalCodes has exactly four codes', () {
      expect(
        kMvpSpeciesInternalCodes,
        {'cat_sco', 'cat_rag', 'dog_pom', 'dog_bic'},
      );
    });

    test('id mapping matches Supabase', () {
      expect(kSpeciesIdentityById[1]?.internalCode, 'cat_sco');
      expect(kSpeciesIdentityById[2]?.internalCode, 'cat_rag');
      expect(kSpeciesIdentityById[3]?.internalCode, 'dog_pom');
      expect(kSpeciesIdentityById[4]?.internalCode, 'dog_bic');
    });

    test('legacy non-MVP identities are removed', () {
      expect(kSpeciesIdentityById.containsKey(5), isFalse);
      expect(kSpeciesIdentityById.containsKey(6), isFalse);
      expect(kSpeciesIdentityByOldName.containsKey('cat_kor'), isFalse);
      expect(kSpeciesIdentityByOldName.containsKey('dog_pud'), isFalse);
      expect(kSpeciesIdentityByOldName.containsKey('코리'), isFalse);
      expect(kSpeciesIdentityByOldName.containsKey('푸리'), isFalse);
    });

    test('speciesIdentityFromSpeciesRow prefers code over id', () {
      final row = <String, dynamic>{
        'id': 99,
        'code': 'dog_pom',
        'name_ko': '포메라니안',
        'name_en': 'Pom',
        'family': 'dog',
      };
      final identity = speciesIdentityFromSpeciesRow(row);
      expect(identity?.id, 3);
      expect(identity?.internalCode, 'dog_pom');
    });

    test('isMvpSpeciesId / isMvpSpeciesInternalCode', () {
      expect(isMvpSpeciesId(3), isTrue);
      expect(isMvpSpeciesId(4), isTrue);
      expect(isMvpSpeciesId(5), isFalse);
      expect(isMvpSpeciesInternalCode('dog_bic'), isTrue);
      expect(isMvpSpeciesInternalCode('cat_kor'), isFalse);
    });
  });
}
