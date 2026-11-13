-- =========================================================
-- 03_rpc.sql : 앱에서 부르는 기능들 (여러 번 실행해도 안전)
-- =========================================================

-- 초대 링크 만들기: 회원 초대 = 직원·관리자, 직원 초대 = 관리자만
create or replace function public.create_invite(p_role text default 'member', p_branch text default null)
returns text language plpgsql security definer set search_path = public as $$
declare me profiles%rowtype; t text;
begin
  select * into me from profiles where id = auth.uid();
  if me.role not in ('staff','admin') then raise exception 'not_staff'; end if;
  if p_role not in ('member','staff') then raise exception 'bad_role'; end if;
  if p_role = 'staff' and me.role <> 'admin' then raise exception 'admin_only'; end if;
  t := replace(gen_random_uuid()::text, '-', '');
  insert into invites(token, role, branch, trainer_id, created_by)
  values (t, p_role,
          case when me.role = 'admin' then coalesce(p_branch, me.branch) else me.branch end,
          case when p_role = 'member' and me.role = 'staff' then me.id end,
          me.id);
  return t;
end $$;

-- 초대 링크 미리보기 (로그인 전에도 호출)
create or replace function public.peek_invite(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_build_object('ok', true, 'role', i.role, 'branch', i.branch,
                              'trainer', (select name from profiles where id = i.trainer_id))
    from invites i where i.token = p_token and i.used_at is null and i.expires_at > now()
  ), jsonb_build_object('ok', false)) $$;

-- 직원 가입 승인/거절 (관리자)
create or replace function public.review_staff(p_user uuid, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin_only'; end if;
  update profiles set role = case when p_ok then 'staff' else 'rejected' end
   where id = p_user and role = 'applicant';
end $$;

-- 담당 지정/해제
-- 직원: 볼 수 있는 회원을 '나'로 지정하거나, 내 회원을 해제
-- 관리자: 아무 회원이나 아무 직원으로 지정/해제
create or replace function public.assign_trainer(p_member uuid, p_trainer uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me profiles%rowtype; m profiles%rowtype;
begin
  select * into me from profiles where id = auth.uid();
  select * into m from profiles where id = p_member and role = 'member';
  if not found then raise exception 'no_member'; end if;
  if me.role = 'admin' then
    if p_trainer is not null and not exists
       (select 1 from profiles where id = p_trainer and role in ('staff','admin')) then
      raise exception 'bad_trainer';
    end if;
  elsif me.role = 'staff' then
    if not public.can_see_member(p_member) then raise exception 'forbidden'; end if;
    if p_trainer is not null and p_trainer <> me.id then raise exception 'forbidden'; end if;
    if p_trainer is null and m.trainer_id is distinct from me.id then raise exception 'forbidden'; end if;
  else
    raise exception 'not_staff';
  end if;
  update profiles set trainer_id = p_trainer where id = p_member;
end $$;

-- 직원이 회원 목표 설정
create or replace function public.set_member_goal(p_member uuid, p_goal jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_staff() and public.can_see_member(p_member)) then raise exception 'forbidden'; end if;
  update profiles set goal = coalesce(p_goal, '{}'::jsonb) where id = p_member and role = 'member';
end $$;

-- 가입 열림 여부 (로그인 전에도 호출)
create or replace function public.open_signup_on() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value::text::boolean from app_settings where key='open_signup'), false) $$;
create or replace function public.open_staff_signup_on() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value::text::boolean from app_settings where key='open_staff_signup'), false) $$;

-- 관리자 설정 바꾸기
create or replace function public.set_setting(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin_only'; end if;
  if p_key not in ('open_signup','open_staff_signup','ai_daily_limit') then raise exception 'bad_key'; end if;
  insert into app_settings(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value;
end $$;

-- 음식 검색: 정확히 같은 이름 → 앞글자 일치 → 아르더짐 검수 → 공공데이터 → 유저등록 순
create or replace function public.search_foods(q text, lim int default 20)
returns setof public.foods language sql stable set search_path = public as $$
  select f.* from foods f
  where length(trim(coalesce(q,''))) > 0
    and (f.name ilike '%' || trim(q) || '%' or similarity(f.name, trim(q)) > 0.3)
  order by (f.name = trim(q)) desc,
           (f.name ilike trim(q) || '%') desc,
           case f.source when 'ardor' then 0 when 'public' then 1 else 2 end,
           similarity(f.name, trim(q)) desc,
           length(f.name)
  limit greatest(1, least(coalesce(lim, 20), 50)) $$;

-- AI 사진 분석 1회 사용 (하루 한도 넘으면 오류). 남은 횟수를 돌려줘요.
create or replace function public.ai_take_quota() returns int
language plpgsql security definer set search_path = public as $$
declare lim int; used int;
begin
  if auth.uid() is null or public.my_role() not in ('member','staff','admin') then
    raise exception 'not_allowed';
  end if;
  lim := coalesce((select value::text::int from app_settings where key='ai_daily_limit'), 20);
  select count(*) into used from ai_usage
   where user_id = auth.uid() and (used_at at time zone 'Asia/Seoul')::date = public.kst_today();
  if used >= lim then raise exception 'ai_limit'; end if;
  insert into ai_usage(user_id) values (auth.uid());
  return lim - used - 1;
end $$;

-- 실행 권한
revoke execute on function public.create_invite(text,text), public.review_staff(uuid,boolean),
  public.assign_trainer(uuid,uuid), public.set_member_goal(uuid,jsonb), public.set_setting(text,jsonb),
  public.ai_take_quota() from public, anon;
grant execute on function public.create_invite(text,text), public.review_staff(uuid,boolean),
  public.assign_trainer(uuid,uuid), public.set_member_goal(uuid,jsonb), public.set_setting(text,jsonb),
  public.ai_take_quota(), public.search_foods(text,int) to authenticated;
grant execute on function public.peek_invite(text), public.open_signup_on(), public.open_staff_signup_on()
  to anon, authenticated;
