-- =====================================================================
-- 아르더짐 회원 체크 앱 · Supabase 스키마 (SQL Editor에 통째로 붙여넣고 Run)
-- 여러 번 실행해도 되도록(idempotent) 작성했습니다.
-- 구성: 프로필/권한 → 초대 → 기록 → 사진(Storage) → 피드백 → 가입정보 → 음식 DB → 알림
-- =====================================================================

-- ---------- 1. 프로필 ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  login_id    text not null unique check (login_id ~ '^[a-z][a-z0-9_-]{3,15}$'),
  name        text not null,
  branch      text not null check (branch in ('mangpo','seocheon')),   -- mangpo=망포점, seocheon=서천점
  role        text not null default 'member' check (role in ('member','staff','admin')),
  goal        jsonb,                                                    -- 회원이 정한 {kcal,carb,prot,fat}
  created_at  timestamptz not null default now()
);

-- ---------- 2. 권한 판별 함수 (RLS 재귀를 피하려고 security definer) ----------
create or replace function public.my_role() returns text
  language sql stable security definer set search_path = public as
$$ select role from public.profiles where id = auth.uid() $$;

create or replace function public.my_branch() returns text
  language sql stable security definer set search_path = public as
$$ select branch from public.profiles where id = auth.uid() $$;

create or replace function public.is_staff() returns boolean
  language sql stable security definer set search_path = public as
$$ select coalesce((select role in ('staff','admin') from public.profiles where id = auth.uid()), false) $$;

-- "나" 또는 "내가 볼 수 있는 회원"인가: 본인 / 같은 지점 직원 / 관리자
create or replace function public.can_see_member(m uuid) returns boolean
  language sql stable security definer set search_path = public as
$$
  select m = auth.uid() or exists (
    select 1 from public.profiles me join public.profiles t on t.id = m
    where me.id = auth.uid() and (me.role = 'admin' or (me.role = 'staff' and me.branch = t.branch))
  )
$$;

-- Storage 경로 "<회원uuid>/..." 에서 회원 id를 뽑아 같은 판별을 한다 (uuid가 아니면 false)
create or replace function public.can_see_path(p text) returns boolean
  language plpgsql stable security definer set search_path = public as
$$
begin
  return public.can_see_member((split_part(p, '/', 1))::uuid);
exception when others then
  return false;
end
$$;

-- 한국 날짜 (기록은 "오늘"만 쓰고 고칠 수 있다)
create or replace function public.kst_today() returns date
  language sql stable as $$ select (now() at time zone 'Asia/Seoul')::date $$;

-- ---------- 3. 초대 ----------
create table if not exists public.invites (
  token       text primary key,
  name        text not null,
  role        text not null default 'member' check (role in ('member','staff','admin')),
  branch      text not null check (branch in ('mangpo','seocheon')),
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  used_by     uuid references auth.users(id) on delete set null,
  used_at     timestamptz
);

-- 링크 토큰 만들기: 직원/관리자만. 직원은 자기 지점 회원만, 직원·관리자 초대는 관리자만.
create or replace function public.create_invite(p_name text, p_role text default 'member', p_branch text default null)
returns text language plpgsql security definer set search_path = public as
$$
declare
  me public.profiles; b text; tok text := ''; i int; bytes bytea;
  alphabet constant text := 'abcdefghjkmnpqrstuvwxyz23456789';   -- 헷갈리는 글자(i,l,o,0,1) 제외, 31자
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or me.role not in ('staff','admin') then raise exception 'forbidden'; end if;
  p_name := btrim(coalesce(p_name, ''));
  if length(p_name) = 0 or length(p_name) > 30 then raise exception 'invalid_name'; end if;
  if p_role not in ('member','staff','admin') then raise exception 'invalid_role'; end if;
  if p_role <> 'member' and me.role <> 'admin' then raise exception 'forbidden_role'; end if;
  b := case when me.role = 'admin' then coalesce(p_branch, me.branch) else me.branch end;
  if b not in ('mangpo','seocheon') then raise exception 'invalid_branch'; end if;
  -- gen_random_uuid()는 암호학적 난수. 버전/변형 비트가 있는 6,8번째 바이트는 뺀다.
  bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
  for i in 0..9 loop
    tok := tok || substr(alphabet, 1 + (get_byte(bytes, case when i < 6 then i else i + 3 end) % 31), 1);
  end loop;
  insert into public.invites(token, name, role, branch, created_by) values (tok, p_name, p_role, b, auth.uid());
  return tok;
end
$$;

-- 가입 화면에서 링크가 유효한지 확인 (로그인 전이라 anon 허용). 이름·지점·역할만 돌려준다.
create or replace function public.peek_invite(p_token text) returns jsonb
  language plpgsql stable security definer set search_path = public as
$$
declare r public.invites;
begin
  select * into r from public.invites where token = lower(btrim(coalesce(p_token, '')));
  if not found then return jsonb_build_object('status', 'none'); end if;
  if r.used_by is not null or r.used_at is not null then return jsonb_build_object('status', 'used'); end if;
  return jsonb_build_object('status', 'ok', 'name', r.name, 'branch', r.branch, 'role', r.role);
end
$$;

-- 가입 = 초대 링크 필수. auth.users에 행이 생길 때 초대를 확인하고 프로필을 만든다.
-- 초대가 없거나 이미 쓰였으면 예외를 던져서 가입 자체가 취소된다.
create or replace function public.handle_new_user() returns trigger
  language plpgsql security definer set search_path = public as
$$
declare
  tok text := lower(coalesce(new.raw_user_meta_data->>'invite', ''));
  lid text := lower(coalesce(new.raw_user_meta_data->>'login_id', ''));
  inv public.invites;
begin
  select * into inv from public.invites where token = tok for update;
  if not found or inv.used_by is not null or inv.used_at is not null then raise exception 'invalid_invite'; end if;
  if lid !~ '^[a-z][a-z0-9_-]{3,15}$' then raise exception 'invalid_login_id'; end if;
  if split_part(coalesce(new.email, ''), '@', 1) <> lid then raise exception 'login_id_mismatch'; end if;
  insert into public.profiles(id, login_id, name, branch, role) values (new.id, lid, inv.name, inv.branch, inv.role);
  update public.invites set used_by = new.id, used_at = now() where token = tok;
  return new;
end
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 4. 하루 기록 ----------
create table if not exists public.daily_records (
  member_id    uuid not null references public.profiles(id) on delete cascade,
  record_date  date not null,
  status       text not null check (status in ('done','partial')),
  weight       numeric(5,1),
  sleep        numeric(3,1),
  steps        integer check (steps is null or steps between 0 and 100000),
  water        numeric(3,1),
  muscle       numeric(4,1),
  body_fat     numeric(4,1),
  trained      text check (trained in ('pt','self','rest')),
  cond         smallint check (cond between 1 and 5),
  fatigue      smallint check (fatigue between 1 and 5),
  stress       smallint check (stress between 1 and 5),
  pain         text[] not null default '{}',
  pain_level   text check (pain_level in ('약','중','강')),
  goal         jsonb,
  workouts     jsonb not null default '[]',
  meals        jsonb not null default '[]',
  tot          jsonb,
  updated_at   timestamptz not null default now(),
  primary key (member_id, record_date)
);
create index if not exists daily_records_date_idx on public.daily_records(record_date);

-- ---------- 5. 식사 사진 (파일은 Storage, 여기엔 경로만) ----------
create table if not exists public.meal_photos (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references public.profiles(id) on delete cascade,
  record_date  date not null,
  slot         text not null check (slot in ('아침','점심','저녁','간식')),
  path         text not null unique,
  created_at   timestamptz not null default now()
);
create index if not exists meal_photos_member_idx on public.meal_photos(member_id, record_date);
create index if not exists meal_photos_created_idx on public.meal_photos(created_at);

-- ---------- 6. 트레이너 피드백 ----------
create table if not exists public.feedback (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references public.profiles(id) on delete cascade,
  record_date  date not null,
  slot         text not null check (slot in ('아침','점심','저녁','간식')),
  author_id    uuid references public.profiles(id) on delete set null,
  author_name  text,
  text         text not null check (length(text) between 1 and 500),
  created_at   timestamptz not null default now()
);
create index if not exists feedback_member_idx on public.feedback(member_id, record_date);

-- 작성자 이름·id는 서버가 채운다 (직원이 다른 사람 이름으로 못 쓰게)
create or replace function public.feedback_fill() returns trigger
  language plpgsql security definer set search_path = public as
$$
begin
  new.author_id := auth.uid();
  select name into new.author_name from public.profiles where id = auth.uid();
  return new;
end
$$;
drop trigger if exists feedback_fill_trg on public.feedback;
create trigger feedback_fill_trg before insert on public.feedback
  for each row execute function public.feedback_fill();

-- ---------- 7. 가입 시 작성한 정보 ----------
create table if not exists public.intake (
  member_id   uuid primary key references public.profiles(id) on delete cascade,
  data        jsonb not null,       -- goals, exp, freq, times, act, meals, eatout, src, sens(동의 시에만)
  consent     jsonb not null,       -- age14, privacy, sensitive, at, ver
  created_at  timestamptz not null default now()
);

-- ---------- 8. 음식 DB ----------
create table if not exists public.foods (
  code        text primary key,                  -- 기록에 저장되는 음식 id (fid)
  name        text not null,
  category    text not null default '기타',
  source      text not null check (source in ('A','P')),   -- A=아르더짐 검수, P=공공 데이터
  kcal        numeric not null check (kcal >= 0),          -- 100g 기준
  carb        numeric not null check (carb >= 0),
  prot        numeric not null check (prot >= 0),
  fat         numeric not null check (fat >= 0),
  units       jsonb not null default '[]',                 -- [["공기",210],["인분",250]]
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists foods_name_idx on public.foods(name);

-- ---------- 9. 알림 구독 ----------
create table if not exists public.push_subscriptions (
  id               uuid primary key default gen_random_uuid(),
  member_id        uuid not null references public.profiles(id) on delete cascade,
  endpoint         text not null unique,
  p256dh           text not null,
  auth             text not null,
  remind_time      time not null default '20:00',
  notify_feedback  boolean not null default true,
  last_sent        date,
  created_at       timestamptz not null default now()
);

-- =====================================================================
-- 권한(RLS): 전부 켜고, 로그인 전(anon)에는 아무것도 못 보게 한다.
-- =====================================================================
alter table public.profiles           enable row level security;
alter table public.invites            enable row level security;
alter table public.daily_records      enable row level security;
alter table public.meal_photos        enable row level security;
alter table public.feedback           enable row level security;
alter table public.intake             enable row level security;
alter table public.foods              enable row level security;
alter table public.push_subscriptions enable row level security;

-- profiles: 본인/같은 지점 직원/관리자가 읽는다. 회원은 자기 goal만 고칠 수 있다.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (public.can_see_member(id));
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- invites: 직원은 자기 지점(관리자는 전체) 초대를 보고, 아직 안 쓴 것만 취소(삭제). 만들기는 create_invite()로만.
drop policy if exists invites_select on public.invites;
create policy invites_select on public.invites for select to authenticated
  using (public.is_staff() and (public.my_role() = 'admin' or branch = public.my_branch()));
drop policy if exists invites_delete on public.invites;
create policy invites_delete on public.invites for delete to authenticated
  using (public.is_staff() and used_by is null and (public.my_role() = 'admin' or branch = public.my_branch()));

-- daily_records: 본인은 "오늘" 것만 쓰고 고친다. 직원은 읽기만.
drop policy if exists rec_select on public.daily_records;
create policy rec_select on public.daily_records for select to authenticated using (public.can_see_member(member_id));
drop policy if exists rec_insert on public.daily_records;
create policy rec_insert on public.daily_records for insert to authenticated
  with check (member_id = auth.uid() and record_date = public.kst_today());
drop policy if exists rec_update on public.daily_records;
create policy rec_update on public.daily_records for update to authenticated
  using (member_id = auth.uid() and record_date = public.kst_today())
  with check (member_id = auth.uid() and record_date = public.kst_today());

-- meal_photos
drop policy if exists ph_select on public.meal_photos;
create policy ph_select on public.meal_photos for select to authenticated using (public.can_see_member(member_id));
drop policy if exists ph_insert on public.meal_photos;
create policy ph_insert on public.meal_photos for insert to authenticated
  with check (member_id = auth.uid() and record_date = public.kst_today() and path like auth.uid()::text || '/%');
drop policy if exists ph_delete on public.meal_photos;
create policy ph_delete on public.meal_photos for delete to authenticated
  using (member_id = auth.uid() and record_date = public.kst_today());

-- feedback: 직원이 오늘 기록에만 쓴다. 회원은 자기 것만 읽는다.
drop policy if exists fb_select on public.feedback;
create policy fb_select on public.feedback for select to authenticated using (public.can_see_member(member_id));
drop policy if exists fb_insert on public.feedback;
create policy fb_insert on public.feedback for insert to authenticated
  with check (public.is_staff() and member_id <> auth.uid() and public.can_see_member(member_id) and record_date = public.kst_today());

-- intake: 본인이 가입 직후 한 번 쓰고, 본인과 담당 직원이 읽는다.
drop policy if exists intake_select on public.intake;
create policy intake_select on public.intake for select to authenticated using (public.can_see_member(member_id));
drop policy if exists intake_insert on public.intake;
create policy intake_insert on public.intake for insert to authenticated with check (member_id = auth.uid());

-- foods: 로그인한 사람은 읽고, 직원/관리자만 추가·수정·삭제
drop policy if exists foods_select on public.foods;
create policy foods_select on public.foods for select to authenticated using (active or public.is_staff());
drop policy if exists foods_write on public.foods;
create policy foods_write on public.foods for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- push_subscriptions: 본인 것만
drop policy if exists subs_all on public.push_subscriptions;
create policy subs_all on public.push_subscriptions for all to authenticated
  using (member_id = auth.uid()) with check (member_id = auth.uid());

-- ---------- 테이블 권한: 필요한 것만 남기고 모두 회수 ----------
revoke all on all tables in schema public from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (goal) on public.profiles to authenticated;
grant select, delete on public.invites to authenticated;
grant select, insert, update on public.daily_records to authenticated;
grant select, insert, delete on public.meal_photos to authenticated;
grant select, insert on public.feedback to authenticated;
grant select, insert on public.intake to authenticated;
grant select, insert, update, delete on public.foods to authenticated;
grant select, insert, update, delete on public.push_subscriptions to authenticated;

-- 함수 실행 권한: 기본값(모두 허용)을 걷어내고 필요한 것만 연다
revoke execute on function public.create_invite(text, text, text) from public, anon;
revoke execute on function public.peek_invite(text) from public;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.feedback_fill() from public, anon, authenticated;
grant execute on function public.create_invite(text, text, text) to authenticated;
grant execute on function public.peek_invite(text) to anon, authenticated;
grant execute on function public.my_role(), public.my_branch(), public.is_staff(),
  public.can_see_member(uuid), public.can_see_path(text), public.kst_today() to authenticated;

-- =====================================================================
-- 식사 사진 저장소 (비공개). 파일 경로: <회원uuid>/<날짜>/<끼니>_<토큰>.jpg
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('meal-photos', 'meal-photos', false, 1048576, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];

drop policy if exists "meal photos insert own" on storage.objects;
create policy "meal photos insert own" on storage.objects for insert to authenticated
  with check (bucket_id = 'meal-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "meal photos read" on storage.objects;
create policy "meal photos read" on storage.objects for select to authenticated
  using (bucket_id = 'meal-photos' and public.can_see_path(name));
drop policy if exists "meal photos delete own" on storage.objects;
create policy "meal photos delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'meal-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- =====================================================================
-- 실시간 반영(직원 화면에 새 기록이 바로 뜨도록)
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['daily_records','meal_photos','feedback','invites','profiles'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- =====================================================================
-- 예약 작업 (Dashboard > Database > Extensions 에서 pg_cron, pg_net 켠 뒤 실행)
-- <PROJECT_REF>, <CRON_SECRET> 을 바꿔서 쓰세요. 아래는 주석 처리돼 있습니다.
-- =====================================================================
-- 10분마다 체크 알림:
-- select cron.schedule('ardor-reminders', '*/10 * * * *', $$
--   select net.http_post(url := 'https://<PROJECT_REF>.supabase.co/functions/v1/send-reminders',
--     headers := jsonb_build_object('Content-Type','application/json','x-cron-secret','<CRON_SECRET>'),
--     body := '{}'::jsonb) $$);
-- 매일 새벽 3:30(한국시간) 오래된 식사 사진 삭제:
-- select cron.schedule('ardor-purge-photos', '30 18 * * *', $$
--   select net.http_post(url := 'https://<PROJECT_REF>.supabase.co/functions/v1/purge-photos',
--     headers := jsonb_build_object('Content-Type','application/json','x-cron-secret','<CRON_SECRET>'),
--     body := '{}'::jsonb) $$);
