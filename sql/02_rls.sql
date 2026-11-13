-- =========================================================
-- 02_rls.sql : 권한 규칙(RLS) + 가입 처리 (여러 번 실행해도 안전)
-- 01_schema.sql 다음에 실행하세요.
-- =========================================================

-- ---------- 도우미 함수 ----------
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() $$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('staff','admin') from profiles where id = auth.uid()), false) $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' from profiles where id = auth.uid()), false) $$;

create or replace function public.my_trainer_id() returns uuid
language sql stable security definer set search_path = public as $$
  select trainer_id from profiles where id = auth.uid() $$;

-- 본인 → O / 관리자 → O / 직원 → 같은 지점 AND (회원이 아니거나, 담당 미지정이거나, 내 회원)
create or replace function public.can_see_member(m uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null then false
    when m = auth.uid() then true
    else exists (
      select 1 from profiles me join profiles t on t.id = m
      where me.id = auth.uid() and (
        me.role = 'admin'
        or (me.role = 'staff' and t.branch = me.branch
            and (t.role <> 'member' or t.trainer_id is null or t.trainer_id = me.id))))
  end $$;

-- 오늘 포함 최근 7일
create or replace function public.in_edit_window(d date) returns boolean
language sql stable as $$ select d between public.kst_today() - 6 and public.kst_today() $$;

-- ---------- 가입 처리 (auth.users에 새 계정이 생기면 프로필 자동 생성) ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  md jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_login text := lower(coalesce(md->>'login_id', split_part(new.email, '@', 1)));
  v_kind  text := coalesce(md->>'kind', 'member');      -- member | staff
  v_token text := nullif(md->>'invite', '');
  v_branch text := coalesce(nullif(md->>'branch',''), '망포');
  v_role text; v_trainer uuid; inv invites%rowtype;
begin
  if v_login !~ '^[a-z][a-z0-9_]{3,15}$' then
    raise exception 'bad_login_id';
  end if;

  if v_token is not null then
    select * into inv from invites
     where token = v_token and used_at is null and expires_at > now() for update;
    if not found then raise exception 'invite_invalid'; end if;
    if (inv.role = 'staff') <> (v_kind = 'staff') then raise exception 'invite_wrong_site'; end if;
    v_role := inv.role; v_branch := inv.branch;
    v_trainer := case when inv.role = 'member' then inv.trainer_id end;
    update invites set used_at = now(), used_by = null where token = v_token;
  elsif v_kind = 'staff' then
    if not coalesce((select value::text::boolean from app_settings where key='open_staff_signup'), false) then
      raise exception 'staff_signup_closed';
    end if;
    v_role := 'applicant';
  else
    if not coalesce((select value::text::boolean from app_settings where key='open_signup'), false) then
      raise exception 'signup_closed';
    end if;
    v_role := 'member';
  end if;

  insert into profiles(id, login_id, name, branch, role, trainer_id, consent_at)
  values (new.id, v_login, coalesce(md->>'name',''), v_branch, v_role, v_trainer,
          case when v_kind = 'member' then now() end);

  if v_token is not null then
    update invites set used_by = new.id where token = v_token;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- RLS 켜기 ----------
alter table public.profiles      enable row level security;
alter table public.daily_records enable row level security;
alter table public.meal_photos   enable row level security;
alter table public.feedback      enable row level security;
alter table public.foods         enable row level security;
alter table public.intake        enable row level security;
alter table public.invites       enable row level security;
alter table public.app_settings  enable row level security;
alter table public.ai_usage      enable row level security;

-- profiles: 본인/볼 수 있는 회원/내 담당 트레이너만 보기. 본인은 이름·목표만 수정
drop policy if exists p_profiles_sel on public.profiles;
create policy p_profiles_sel on public.profiles for select to authenticated
  using (id = auth.uid() or public.can_see_member(id) or id = public.my_trainer_id());
drop policy if exists p_profiles_upd on public.profiles;
create policy p_profiles_upd on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated;
grant update (name, goal) on public.profiles to authenticated;

-- daily_records: 보기는 can_see_member, 쓰기는 본인 + 최근 7일
drop policy if exists p_rec_sel on public.daily_records;
create policy p_rec_sel on public.daily_records for select to authenticated
  using (public.can_see_member(member_id));
drop policy if exists p_rec_ins on public.daily_records;
create policy p_rec_ins on public.daily_records for insert to authenticated
  with check (member_id = auth.uid() and public.in_edit_window(record_date));
drop policy if exists p_rec_upd on public.daily_records;
create policy p_rec_upd on public.daily_records for update to authenticated
  using (member_id = auth.uid() and public.in_edit_window(record_date))
  with check (member_id = auth.uid() and public.in_edit_window(record_date));

-- meal_photos
drop policy if exists p_ph_sel on public.meal_photos;
create policy p_ph_sel on public.meal_photos for select to authenticated
  using (public.can_see_member(member_id));
drop policy if exists p_ph_ins on public.meal_photos;
create policy p_ph_ins on public.meal_photos for insert to authenticated
  with check (member_id = auth.uid() and public.in_edit_window(record_date));
drop policy if exists p_ph_del on public.meal_photos;
create policy p_ph_del on public.meal_photos for delete to authenticated
  using (member_id = auth.uid() and public.in_edit_window(record_date));

-- feedback: 직원만 작성(최근 7일, 볼 수 있는 회원), 작성자만 수정·삭제
drop policy if exists p_fb_sel on public.feedback;
create policy p_fb_sel on public.feedback for select to authenticated
  using (public.can_see_member(member_id));
drop policy if exists p_fb_ins on public.feedback;
create policy p_fb_ins on public.feedback for insert to authenticated
  with check (public.is_staff() and author_id = auth.uid()
              and public.can_see_member(member_id) and public.in_edit_window(record_date));
drop policy if exists p_fb_upd on public.feedback;
create policy p_fb_upd on public.feedback for update to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());
drop policy if exists p_fb_del on public.feedback;
create policy p_fb_del on public.feedback for delete to authenticated
  using (author_id = auth.uid());

-- foods: 로그인한 사람 모두 보기. 회원은 '유저등록'만 추가, 직원은 아르더짐 검수도 추가
drop policy if exists p_food_sel on public.foods;
create policy p_food_sel on public.foods for select to authenticated using (true);
drop policy if exists p_food_ins on public.foods;
create policy p_food_ins on public.foods for insert to authenticated
  with check (created_by = auth.uid() and (source = 'user' or (source = 'ardor' and public.is_staff())));
drop policy if exists p_food_upd on public.foods;
create policy p_food_upd on public.foods for update to authenticated
  using (public.is_staff() or (created_by = auth.uid() and source = 'user'))
  with check (public.is_staff() or (created_by = auth.uid() and source = 'user'));
drop policy if exists p_food_del on public.foods;
create policy p_food_del on public.foods for delete to authenticated
  using (public.is_admin() or (created_by = auth.uid() and source = 'user'));

-- intake: 본인 작성, 볼 수 있는 직원 열람
drop policy if exists p_in_sel on public.intake;
create policy p_in_sel on public.intake for select to authenticated
  using (public.can_see_member(member_id));
drop policy if exists p_in_ins on public.intake;
create policy p_in_ins on public.intake for insert to authenticated
  with check (member_id = auth.uid());
drop policy if exists p_in_upd on public.intake;
create policy p_in_upd on public.intake for update to authenticated
  using (member_id = auth.uid()) with check (member_id = auth.uid());

-- invites: 만든 사람(직원)만 목록 보기. 만들기는 RPC로만
drop policy if exists p_inv_sel on public.invites;
create policy p_inv_sel on public.invites for select to authenticated
  using (created_by = auth.uid() or public.is_admin());

-- app_settings: 읽기는 RPC로, 관리자는 직접 읽기
drop policy if exists p_set_sel on public.app_settings;
create policy p_set_sel on public.app_settings for select to authenticated using (public.is_admin());

-- ai_usage: 본인 기록만 보기 (추가는 ai_take_quota RPC로)
drop policy if exists p_ai_sel on public.ai_usage;
create policy p_ai_sel on public.ai_usage for select to authenticated using (user_id = auth.uid());
