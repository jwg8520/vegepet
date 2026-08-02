-- profiles: Google/Apple 계정 연동 후 email / account_type / linked_at UPDATE 가
-- 0행으로 떨어지는 경우를 막기 위한 소유자 RLS 정책 점검/보강.
--
-- 소유권 키는 profiles.id (= auth.users.id = auth.uid()) 이다.
-- anonymous Supabase 세션도 JWT role 은 authenticated 를 사용하므로
-- to authenticated 정책을 사용한다. anon 전용으로 제한하지 않는다.
--
-- 이미 동일 목적의 정책이 Dashboard 에 있으면 있다면 중복 생성하지 말고,
-- USING / WITH CHECK 조건이 auth.uid() = id 인지 먼저 확인한다.
-- 잘못 user_id 컬럼을 참조하는 정책이 있다면 제거 후 아래를 적용한다.

alter table public.profiles enable row level security;

-- SELECT: 자신의 row 만
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
on public.profiles
for select
to authenticated
using (auth.uid() = id);

-- UPDATE: 자신의 row 만 (USING + WITH CHECK 모두 필요)
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles
for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

-- 참고: INSERT/UPSERT 용 기존 정책이 있다면 그대로 유지한다.
-- 예) profiles_insert_own / profiles_upsert_own 등은 삭제하지 않는다.
