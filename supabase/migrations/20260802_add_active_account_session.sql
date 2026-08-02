-- 단일 활성 기기 정책: 같은 계정이 새 기기에서 로그인하면 서버의
-- profiles.active_session_id 가 새 기기 값으로 교체되고, 이전 기기는 자신의
-- 로컬 세션 식별자와 다름을 감지해 그 기기에서만 로그아웃한다.
--
-- active_session_id 는 Auth 토큰/사용자 UUID 가 아닌 순수 랜덤 문자열이다.
-- 기존 profiles RLS(자기 행 SELECT/UPDATE)로 충분하므로 새 정책을 만들지 않는다.
--   using (auth.uid() = id)
--   with check (auth.uid() = id)

alter table public.profiles
add column if not exists active_session_id text;

alter table public.profiles
add column if not exists active_session_updated_at timestamptz;

comment on column public.profiles.active_session_id is
'Latest active VegePet app login session identifier';

comment on column public.profiles.active_session_updated_at is
'When active_session_id was last replaced by a signing-in device';
