-- =========================================================
-- ai_photo.sql : AI 사진 분석용 추가 (원래 Supabase에 1번 실행)
-- 기존 테이블·권한·함수는 건드리지 않고 새 것만 더해요. 여러 번 실행해도 안전해요.
-- =========================================================

-- 1) AI 사용 기록 (하루 한도 계산용)
create table if not exists public.ai_usage (
  id       bigserial primary key,
  user_id  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  used_at  timestamptz not null default now()
);
create index if not exists ai_usage_user_time on public.ai_usage (user_id, used_at);
alter table public.ai_usage enable row level security;
drop policy if exists ai_usage_select_own on public.ai_usage;
create policy ai_usage_select_own on public.ai_usage for select to authenticated using (user_id = auth.uid());

-- 2) 하루 한도 설정 (1인당 20회). 바꾸려면 아래 숫자만 고쳐서 update 문을 실행하세요.
insert into public.app_settings (key, value)
select 'ai_daily_limit', '20'
where not exists (select 1 from public.app_settings where key = 'ai_daily_limit');
-- 예) update public.app_settings set value = '30' where key = 'ai_daily_limit';

-- 3) 1회 사용 처리: 한도를 넘으면 'ai_limit' 오류, 아니면 남은 횟수를 돌려줘요
create or replace function public.ai_take_quota() returns int
language plpgsql security definer set search_path = public as $$
declare lim int; used int; v text;
begin
  if auth.uid() is null or coalesce(public.my_role(), '') not in ('member', 'staff', 'admin') then
    raise exception 'not_allowed';
  end if;
  select value into v from public.app_settings where key = 'ai_daily_limit' limit 1;
  lim := case when v ~ '^\s*\d+\s*$' then btrim(v)::int else 20 end;
  select count(*) into used from public.ai_usage
   where user_id = auth.uid() and (used_at at time zone 'Asia/Seoul')::date = public.kst_today();
  if used >= lim then raise exception 'ai_limit'; end if;
  insert into public.ai_usage (user_id) values (auth.uid());
  return lim - used - 1;
end $$;

revoke execute on function public.ai_take_quota() from public, anon;
grant execute on function public.ai_take_quota() to authenticated;
