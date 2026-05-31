# VegePet Supabase RLS/RPC 보안 점검 설계안

> **문서 목적**: Supabase SQL을 바로 적용하기 전, 검토용 보안 설계안  
> **기준 파일**: `lib/main.dart`, `docs/vegepet_mvp_spec.md`, `docs/wireframe_notes.md`  
> **작성 기준일**: 2026-05-31  
> **상태**: 적용 전 검토용 (코드/SQL 미적용)

---

## 0. 현재 앱 기준 사실 확인

`lib/main.dart`에서 실제로 확인한 Supabase 접근 패턴입니다.

### 0.1 테이블 접근 현황

| 테이블 | 클라이언트 접근 | 비고 |
|---|---|---|
| `profiles` | select, upsert, update | `id = user.id` 필터 사용 |
| `pet_species` | select | 마스터 데이터 read-only |
| `user_pets` | select, insert, update | affection/stage/is_active 등 직접 변경 |
| `user_items` | select, delete | 분양권 수량 조회; 차감은 RPC |
| `meal_logs` | select, insert, delete | Edge Function 경로 + 클라 직접 insert 공존 |
| `meal_diary_notes` | select, upsert, delete | 식단일지 메모 |
| `pokedex_entries` | select, delete | 등록은 RPC; delete 잔존 검증 로직 존재 |
| `storage.objects` (`meal-photos`) | upload | 경로 `{user.id}/{timestamp}_{slot}.jpg` |

### 0.2 RPC / Edge Function 현황

| 이름 | 유형 | 호출 위치 | 역할 |
|---|---|---|---|
| `finalize_pet_graduation` | RPC | `_handleAdultGraduationIfNeeded` | 성숙기 졸업: 도감 등록 + 분양권 지급 + user_pets 갱신 (원자 처리) |
| `use_random_adoption_ticket` | RPC | `_useRandomAdoptionTicketFromBag`, 디버그 | 분양권 1장 차감 + pet_species_id 반환 |
| `meal-evaluate` | Edge Function | `_invokeMealEvaluateFunction` | AI 식단 판정 + meal_logs insert + affection update (서버 처리 가정) |
| `delete-auth-user` | Edge Function | `_deleteCurrentAuthUserByEdgeFunction` | auth.users 행 완전 삭제 (회원탈퇴) |

### 0.3 클라이언트 다중 테이블 순차 delete (트랜잭션 없음)

**회원탈퇴** (`_withdrawAccount`, 약 15281~15322행):

```
meal_logs → meal_diary_notes → pokedex_entries → user_items → user_pets → profiles(update) → delete-auth-user
```

**개발자 초기화** (`_resetForTesting`, 약 4763~4809행, `kDebugMode` 전용):

```
meal_logs → meal_diary_notes → pokedex_entries → user_items → user_pets → profiles(update) → signOut → signInAnonymously
```

두 경로 모두 `TODO(vegepet/security)` 주석으로 "RLS 전제 + security definer RPC 이전 필요"를 명시하고 있습니다.

### 0.4 이미 확인된 위험 신호

1. **`pokedex_entries` delete 후 잔존 검증/재시도** (4771~4792, 15291~15305)  
   → RLS policy 누락 시 delete가 0건 처리되는 현상을 이미 경험했을 가능성이 높음.

2. **랜덤 분양권 race condition**  
   `use_random_adoption_ticket` RPC로 차감(6537) 후, 도감 중복 체크(6566)와 `user_pets` insert(6602)는 **클라이언트에서 별도 수행**. RPC와 실제 분양이 원자적이지 않음.

3. **식단 결과 저장 경로 2개 공존**  
   - 정상: Edge Function `meal-evaluate`가 서버에서 처리 (12668 주석)  
   - 레거시: 클라이언트가 직접 `meal_logs.insert` + `user_pets.affection update` (3931~3945, `result_type:'good'`, `affection_gain:5` 하드코딩)

4. **profiles.email 교차 조회**  
   `_isEmailAlreadyLinkedInProfiles`가 `profiles`에서 `account_type='email' AND email=...`로 **다른 사용자 행을 읽음** (2028~2033).  
   엄격한 `profiles.id = auth.uid()` RLS와 정면 충돌.

5. **Storage 사진 삭제 미구현**  
   주석(4724): "Storage bucket(meal-photos) 의 사진 파일 삭제는 이번 단계에서 다루지 않는다."

6. **`user_pets` update가 id만으로 수행**  
   졸업 펫 비활성화 `update({'is_active':false}).eq('id', ...)` (6589~6592) — `user_id` 필터 없음, RLS에 전적으로 의존.

---

## 1. 테이블별 RLS 정책 목록 (목표)

### 전제 조건

- 모든 대상 테이블: `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`
- 가능하면 `ALTER TABLE ... FORCE ROW LEVEL SECURITY` (서비스 롤 제외 강제)
- 익명(anon) 세션도 `auth.uid()`를 가지므로 게스트도 동일 정책 적용
- 일반 사용자는 **자신의 데이터만** select/insert/update/delete 가능

---

### 1.1 profiles

**소유권 기준**: `id = auth.uid()`

| 동작 | 정책 조건 | 비고 |
|---|---|---|
| SELECT | `id = auth.uid()` | 이메일 중복 검사 교차 조회는 별도 RPC 필요 (4절 참고) |
| INSERT | `WITH CHECK (id = auth.uid())` | 게스트 최초 upsert 대응 |
| UPDATE | `USING (id = auth.uid()) WITH CHECK (id = auth.uid())` | 프로필 패치, 탈퇴 초기화 |
| DELETE | 정책 미생성 (일반 유저 금지) | 탈퇴는 RPC/Edge Function으로 처리 |

**추가 검토**:

- `gold_balance`, `account_type`, `linked_at` 등은 RLS만으로 컬럼 단위 보호 불가 → RPC/트리거로 변경 통제 필요
- `profiles.email` UNIQUE 제약(또는 `WHERE account_type='email'` 부분 유니크 인덱스) 존재 여부 확인 필수

---

### 1.2 user_pets

**소유권 기준**: `user_id = auth.uid()`

| 동작 | 정책 조건 | 비고 |
|---|---|---|
| SELECT | `user_id = auth.uid()` | |
| INSERT | `WITH CHECK (user_id = auth.uid())` | 첫 분양, 랜덤 분양 insert |
| UPDATE | `USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid())` | `is_active` 비활성화 등 |
| DELETE | `user_id = auth.uid()` | 탈퇴/초기화 |

**민감 컬럼**: `affection`, `stage`, `is_resident`, `graduated_at` — 보상 무결성과 직결. 이상적으로는 클라이언트 직접 UPDATE 금지, RPC/Edge Function으로만 변경.

---

### 1.3 user_items

**소유권 기준**: `user_id = auth.uid()`

| 동작 | 정책 조건 | 비고 |
|---|---|---|
| SELECT | `user_id = auth.uid()` | 가방 조회 |
| INSERT | **정책 미생성 (클라 금지)** | 지급은 RPC만 |
| UPDATE | **정책 미생성 (클라 금지)** | 차감/증가는 RPC만 |
| DELETE | `user_id = auth.uid()` | 탈퇴/초기화 |

**MVP 타협안**: INSERT/UPDATE를 클라에 허용하지 않고, 모든 수량 변경을 RPC로 일원화.

---

### 1.4 meal_logs

**소유권 기준**: `user_id = auth.uid()`

| 동작 | 정책 조건 | 비고 |
|---|---|---|
| SELECT | `user_id = auth.uid()` | 식단일지, 오늘 기록 조회 |
| INSERT | **이상적: 클라 금지** (meal-evaluate 서버만) | 레거시 클라 insert(3931) 제거 전까지는 `WITH CHECK (user_id = auth.uid())` 임시 허용 |
| UPDATE | 정책 미생성 | |
| DELETE | `user_id = auth.uid()` | 탈퇴/초기화 |

---

### 1.5 meal_diary_notes

**소유권 기준**: `user_id = auth.uid()`

| 동작 | 정책 조건 | 비고 |
|---|---|---|
| SELECT | `user_id = auth.uid()` | |
| INSERT | `WITH CHECK (user_id = auth.uid())` | |
| UPDATE | `USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid())` | upsert 대응 |
| DELETE | `user_id = auth.uid()` | 탈퇴/초기화 |

---

### 1.6 pokedex_entries

**소유권 기준**: `user_id = auth.uid()`

| 동작 | 정책 조건 | 비고 |
|---|---|---|
| SELECT | `user_id = auth.uid()` | 도감 화면 |
| INSERT | **정책 미생성 (클라 금지)** | `finalize_pet_graduation` RPC만 등록 |
| UPDATE | 정책 미생성 | |
| DELETE | `user_id = auth.uid()` | 탈퇴/초기화 — **DELETE policy 누락 시 0건 처리 위험** |

**권장 DB 제약**: `UNIQUE (user_id, pet_species_id)` — 도감 중복 등록 방지

---

### 1.7 pet_species

**마스터 데이터 — 전체 read-only**

| 동작 | 정책 조건 | 비고 |
|---|---|---|
| SELECT | `USING (true)` | anon/authenticated 모두 read 허용 |
| INSERT | 정책 미생성 | 서비스 롤만 시드 |
| UPDATE | 정책 미생성 | |
| DELETE | 정책 미생성 | |

---

## 2. Storage Policy 목록 (목표)

**버킷**: `meal-photos`  
**경로 규약** (코드 기준): `{auth.uid()}/{timestamp}_{slot}.jpg`  
**핵심 규칙**: path 첫 segment가 `auth.uid()`와 일치해야 함

Supabase Storage RLS에서 첫 폴더 segment: `(storage.foldername(name))[1]`

| 동작 | 정책 조건 |
|---|---|
| SELECT | `bucket_id = 'meal-photos' AND (storage.foldername(name))[1] = auth.uid()::text` |
| INSERT | `WITH CHECK`: 위와 동일 |
| UPDATE | `USING` + `WITH CHECK`: 위와 동일 |
| DELETE | `USING`: 위와 동일 — 탈퇴 시 폴더 정리용 |

### Storage 추가 점검 항목

| 항목 | 목표 | 이유 |
|---|---|---|
| 버킷 public 여부 | **private** | public이면 경로만 알면 식단 사진(개인정보) 노출 |
| 클라이언트 표시 방식 | `createSignedUrl` (단기 서명 URL) | private 버킷 접근 |
| 경로 규약 동기화 | 코드(`12598`)와 정책 1:1 매칭 | 경로 변경 시 정책도 동시 수정 |
| 탈퇴 시 Storage 정리 | MVP 이후 RPC에서 `{uid}/*` 일괄 삭제 | 현재 미구현 (4724) |

---

## 3. RPC / Edge Function 이전 우선순위

| 순위 | 작업 | 현재 형태 | 목표 형태 | 이유 |
|---|---|---|---|---|
| **P0** | 회원탈퇴 전체 삭제 | 클라 다중 테이블 순차 delete | `security definer` RPC (단일 트랜잭션) + `delete-auth-user` | 중간 실패 시 데이터 불일치 (가장 위험) |
| **P0** | 랜덤 분양권 사용 → 분양 | RPC 차감 + 클라 insert 분리 | `use_random_adoption_ticket` 내부에서 user_pets insert까지 원자 처리 | race condition / 이중 분양 |
| **P0** | meal-evaluate 결과 저장 + affection 증가 | Edge Function (서버) + 클라 레거시 경로 공존 | Edge Function이 service_role로만 insert/update, 클라 경로 제거 | affection 무한 위조 |
| **P1** | 개발자 초기화 | 클라 다중 delete (`kDebugMode`) | `debug_reset_user_data` RPC | 탈퇴와 동일한 부분 실패 위험 |
| **P1** | 도감 등록 | `finalize_pet_graduation` RPC (이미 존재) | 클라 직접 insert 차단 + RPC 멱등성 강화 | 위조 등록 방지 |
| **P1** | user_items 차감/지급 | RPC 일부 + 클라 delete | 모든 증감 RPC 일원화 | 수량 조작 방지 |
| **P2** | 성숙기 완료 처리 | `finalize_pet_graduation` (이미 RPC) | `already_graduated` 멱등성 + UNIQUE 제약 확인 | 이미 원자 처리, 검증만 필요 |

### RPC 설계 원칙

**분양권 원자 차감**:

```sql
UPDATE user_items
SET quantity = quantity - 1
WHERE user_id = auth.uid()
  AND item_master_id = (SELECT id FROM item_masters WHERE code = 'random_adoption_ticket')
  AND quantity > 0
RETURNING *;
-- 0건이면 실패 반환. 같은 트랜잭션에서 종 선택 + user_pets insert.
```

**졸업/보상 멱등성**:

- `graduated_at IS NULL` 조건부 UPDATE
- `pokedex_entries(user_id, pet_species_id)` UNIQUE 제약
- RPC 반환값 `already_graduated` 플래그 (클라이언트 4102행에서 이미 처리)

**이메일 중복 검사**:

- `check_email_available(email text) RETURNS boolean` — `security definer` RPC
- 다른 사용자 profile row를 직접 노출하지 않고 boolean만 반환
- `_isEmailAlreadyLinkedInProfiles` (2028) 대체

---

## 4. 지금 당장 위험한 항목 (MVP 출시 전 필수)

| # | 항목 | 근거 | 조치 |
|---|---|---|---|
| 1 | **RLS 미적용 시 전 테이블 무제한 접근** | 클라가 `user_id` 필터에만 의존 | 모든 테이블 RLS enable + policy 적용 (최우선) |
| 2 | **meal_logs 클라 직접 insert + affection 클라 update** | 3931~3945행 | meal-evaluate 서버 경로로 일원화, 레거시 경로 제거 |
| 3 | **탈퇴/초기화 부분 실패** | 15281, 4763 — 트랜잭션 없는 순차 delete | 단일 RPC 트랜잭션으로 이전 |
| 4 | **pokedex_entries delete 0건 처리** | 4771, 15297 — 잔존 검증 코드 존재 | DELETE RLS policy 확인 + RPC 일괄 처리 |
| 5 | **분양권 race / 이중 분양** | 6537 + 6602 분리 | RPC 내부 원자 처리 |
| 6 | **Storage 버킷 public 여부 미확인** | 식단 사진 = 개인정보 | private + signed URL 확인 |
| 7 | **profiles.email 교차 조회 vs RLS 충돌** | 2028 — 다른 사용자 row read | security definer RPC + UNIQUE 제약 |
| 8 | **성숙기 보상/분양권 중복 지급** | finalize_pet_graduation 멱등성 | UNIQUE 제약 + `already_graduated` 검증 |

---

## 5. MVP 이후로 미뤄도 되는 항목

| 항목 | 이유 |
|---|---|
| `gold_balance`, `account_type`, `affection` 컬럼 트리거 잠금 | RPC 경유 원칙으로 1차 차단 가능 |
| `user_items` 구매(상점) RPC화 | 상점 골드 정합성 위주, 단계적 적용 가능 |
| Storage 사진 자동 정리 (탈퇴 시) | private + RLS로 1차 차단, 데이터 잔존은 후순위 |
| `meal-photos` 서명 URL 캐싱/만료 정책 | UX 최적화 |
| 원격 이메일 연동 감지 서버 푸시화 | `_handleRemoteEmailLinkedDetected` hook만 존재 (2104) |
| 감사 로그 / 레이트 리밋 (식단 2회 제한 서버 강제) | 현재 클라 dup 체크(3911)에 의존 |
| `item_masters` 테이블 RLS | 마스터 read-only, pet_species와 동일 패턴 |

---

## 6. 실제 적용 전 백업 / 테스트 순서

### 6.1 백업

1. Supabase 대시보드에서 **수동 백업** (또는 `pg_dump`) — 전체 스냅샷 확보
2. 대상: 8개 테이블 + `storage.objects` 메타 + 기존 policy/RPC 정의

### 6.2 스키마 사전 점검 (읽기 전용 SQL)

적용 전 아래 항목을 확인:

```sql
-- RLS 활성화 여부
SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class
WHERE relname IN (
  'profiles', 'user_pets', 'user_items', 'meal_logs',
  'meal_diary_notes', 'pokedex_entries', 'pet_species'
);

-- 기존 policy 목록
SELECT * FROM pg_policies
WHERE tablename IN (
  'profiles', 'user_pets', 'user_items', 'meal_logs',
  'meal_diary_notes', 'pokedex_entries', 'pet_species'
);

-- UNIQUE 제약 확인
SELECT conname, conrelid::regclass, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid::regclass::text IN ('profiles', 'pokedex_entries')
  AND contype = 'u';

-- meal-photos 버킷 public 여부
SELECT id, name, public FROM storage.buckets WHERE name = 'meal-photos';
```

### 6.3 적용 순서

| 단계 | 작업 | 검증 |
|---|---|---|
| 1 | 스테이징/별도 프로젝트에서 우선 적용 | 운영 직접 적용 금지 |
| 2 | RLS enable + **SELECT 정책** | 앱 read 정상 확인 |
| 3 | INSERT / UPDATE / DELETE 정책 | CRUD 회귀 테스트 |
| 4 | Storage 정책 | 업로드/다운로드 테스트 |
| 5 | RPC / Edge Function 전환 | 원자성·멱등성 테스트 |
| 6 | 클라이언트 레거시 경로 제거 | affection 위조 시도 거부 확인 |
| 7 | 운영 적용 (저트래픽 시간대) | 즉시 롤백 가능 상태 유지 |

### 6.4 권한 매트릭스 테스트 (2계정 A/B)

| 테스트 | 기대 결과 |
|---|---|
| A가 B의 user_pets / meal_logs / pokedex / items select | 0건 |
| A가 B의 user_pets / meal_logs / pokedex / items update/delete | 거부 또는 0건 |
| A가 B의 `meal-photos/{B.uid}/...` 업로드/다운로드 | 거부 |
| A 탈퇴 RPC 실행 후 A 데이터 잔존 | 전 테이블 0건 + auth.users 삭제 |
| 분양권 1장 연타 (동시 2회) | 1마리만 분양, 도감 중복 없음 |
| meal-evaluate 1일 3회 시도 | 3회째 거부 |
| 클라이언트 affection 직접 update 시도 | 거부 |
| pet_species select (anon/authenticated) | 6종 전체 조회 가능 |
| pet_species insert/update/delete | 거부 |

### 6.5 롤백 플랜

- 각 정책에 대해 `DROP POLICY ...` 역순 스크립트를 **적용 전에 미리 작성**
- RLS로 앱이 막히면 `DISABLE ROW LEVEL SECURITY`가 아닌 **정책 추가/수정**으로 해결 (보안 끄기 금지)
- RPC 변경은 `CREATE OR REPLACE` + 이전 버전 백업

---

## 7. 주의사항

### 7.1 RLS policy 누락 시 delete가 0건 처리될 수 있음

PostgREST/Supabase client는 RLS에 의해 delete 대상이 0건이어도 **에러를 반환하지 않을 수 있습니다**.  
앱 코드의 `pokedex_entries` 잔존 검증 로직(4771, 15297)이 이 현상을 이미 감지하고 있습니다.

→ **대응**: DELETE policy를 모든 user-owned 테이블에 반드시 정의. 탈퇴/초기화는 RPC에서 `GET DIAGNOSTICS ... ROW_COUNT`로 검증.

### 7.2 profiles.email UNIQUE / restore 정책

- `_isEmailAlreadyLinkedInProfiles`(2028)는 다른 사용자 profile을 cross-read
- 엄격 RLS 적용 시 이 검사가 항상 false → 중복 이메일 검출 실패
- `profiles.email`에 UNIQUE 제약이 없으면 같은 이메일 다중 프로필 가능
- 회원탈퇴 시 profiles.email=null + auth.users 삭제(`delete-auth-user`)가 모두 성공해야 같은 이메일 재사용 가능 (15314~15315 주석)

→ **대응**: `check_email_available` security definer RPC + `WHERE account_type='email'` 부분 유니크 인덱스.

### 7.3 meal-evaluate는 service_role로만 affection update

- Edge Function이 service_role 키로 DB에 접근해야 클라이언트 RLS를 우회하여 안전하게 write 가능
- 클라이언트 anon/authenticated 키로는 `user_pets.affection` UPDATE policy를 만들지 않는 것이 원칙
- 레거시 클라 insert 경로(3931~3945)는 RLS 적용과 동시에 **반드시 제거**

### 7.4 Storage bucket public 여부

- `meal-photos`가 public이면 RLS와 무관하게 URL만 알면 접근 가능
- **반드시 private** + 클라이언트는 signed URL로만 표시

### 7.5 성숙기 보상 / 분양권 지급 중복 실행 방지

- `finalize_pet_graduation`은 이미 RPC + `already_graduated` 가드(4058~4060, 4102)
- DB 레벨에서 `graduated_at IS NULL` 조건부 UPDATE + `pokedex_entries` UNIQUE 제약으로 이중 방어 필요
- 클라이언트 `_handleAdultGraduationIfNeeded`는 UI 가드일 뿐, 서버 멱등성이 최종 방어선

### 7.6 랜덤 분양권 race condition

- 현재: RPC 차감 → 클라 precheck → user_pets insert (3단계 분리)
- 연타/네트워크 재시도 시 분양권 1장으로 2마리 또는 도감 중복 가능
- RPC 내부에서 `quantity > 0` 원자 차감 + insert + (필요 시) pokedex check를 **단일 트랜잭션**으로 처리

### 7.7 게스트(익명) 계정과 RLS

- Supabase anon sign-in도 `auth.uid()`를 부여하므로 게스트/이메일 연동 사용자 모두 동일 RLS 적용
- `profiles.account_type`은 'guest' / 'email' 구분용이며, RLS 소유권 기준은 `id = auth.uid()`로 통일

### 7.8 개발자 초기화 vs 회원탈퇴

- 개발자 초기화(`kDebugMode`, 4741): release에서 실행 불가 가드 존재
- 그러나 debug 빌드에서도 RLS 없이 동작하면 테스트 데이터가 실제 DB에 영향
- `debug_reset_user_data` RPC는 서버에서도 debug 환경 가드 또는 admin role 확인 권장

### 7.9 문서와 코드 동기화

- Storage 경로 규약, RPC 함수명, Edge Function명은 `lib/main.dart` 상단 상수와 주석에 정의됨
- RLS/Storage policy 변경 시 해당 상수/주석과 반드시 동기화

---

## 부록: 점검 대상 테이블 요약

| 테이블 | RLS 소유권 | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|---|
| profiles | `id = auth.uid()` | ✅ | ✅ | ✅ | ❌ |
| user_pets | `user_id = auth.uid()` | ✅ | ✅ | ✅ (민감 컬럼 RPC 권장) | ✅ |
| user_items | `user_id = auth.uid()` | ✅ | ❌ (RPC) | ❌ (RPC) | ✅ |
| meal_logs | `user_id = auth.uid()` | ✅ | ❌ (서버) | ❌ | ✅ |
| meal_diary_notes | `user_id = auth.uid()` | ✅ | ✅ | ✅ | ✅ |
| pokedex_entries | `user_id = auth.uid()` | ✅ | ❌ (RPC) | ❌ | ✅ |
| pet_species | — | ✅ (전체) | ❌ | ❌ | ❌ |
| storage.objects (meal-photos) | `folder[1] = auth.uid()` | ✅ | ✅ | ✅ | ✅ |

> ✅ = 일반 사용자 허용 (소유권 조건 충족 시)  
> ❌ = 일반 사용자 금지 (서비스 롤 / RPC / Edge Function만)

---

*이 문서는 Supabase SQL 적용 전 검토용입니다. 실제 migration 파일 작성 및 적용은 별도 작업으로 진행합니다.*
